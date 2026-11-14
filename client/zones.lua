-- ============================================
-- Zone System — Client
-- Spatial-grid polling, box/sphere/poly containment,
-- priority layering, conditional activation, vehicle
-- tracking. Runs four threads (containment poll,
-- rules, 300ms heal, vehicle tracking) plus the
-- debug renderer.
-- ============================================

-- ============================================
-- Registry
-- ============================================

local zones       = {}    -- [id] = zone data
local startDebugDraw      -- the debug drawing loop, started when a zone turns debug on; defined below
local zoneCells   = {}    -- [id] = { [cellKey] = true }
local zoneGrid    = {}    -- [cellKey] = { [id] = true }
local insideZones = {}    -- [id] = true
local dbZoneByKey = {}    -- [key] = 'dbzone_<n>': a saved zone by the name it was made with

--- A zone's id from its id or, for a saved zone, its key. A saved zone's id is 'dbzone_<n>', which
--- no resource knows; its key is what it was made with (EnsureZone), so the lookups take that too.
---
--- The saved zone wins a name, as on the server (server/zones.lua's resolve), so a prompt never
--- shows where the server would refuse it.
local function zoneIdOf(idOrKey)
    if idOrKey == nil then return nil end
    return dbZoneByKey[idOrKey] or idOrKey
end

--- The key a saved zone was made with, from its id (nil for a zone that has none).
local function zoneKeyOf(zoneId)
    for key, id in pairs(dbZoneByKey) do
        if id == zoneId then return key end
    end
    return nil
end

--- The enter/exit payload: the server's field names (`zoneId`, `key`) plus the client's own
--- (`label`, `group`): one shape under one event name on both sides.
local function zoneEventPayload(zone)
    return { zoneId = zone.id, key = zoneKeyOf(zone.id), label = zone.label, group = zone.group }
end

-- Forward declarations (defined later, needed before their definition point)
local removeDebugBlips
local ejectFromZone
-- removeZone() clears a zone's weather layer, and sits above where these are defined (a local
-- declared later does not exist to code above it).
local applyZoneWeather
local clearZoneWeather
-- registerZone takes a replaced zone's rules off, and is written above revertZoneRules.
local revertZoneRules

--- whip_core's own name: the owner of every zone registered without an `_owner` stamp.
local CORE = GetCurrentResourceName()

local CELL_SIZE = Config.ZoneCellSize or 50

-- ============================================
-- Spatial Grid
-- ============================================

--- A cell's key: a number, cell x and y packed together. (A string, as it was, made the poll build 81 of them in a
--- new table every time the player crossed a cell: most of the memory the poll made while driving.)
local KEY_OFFSET, KEY_STRIDE = 50000, 100000
local function keyOf(cx, cy) return (cx + KEY_OFFSET) * KEY_STRIDE + (cy + KEY_OFFSET) end

local function getNearbyCellKeys(x, y, range)
    local radius = math.ceil(range / CELL_SIZE)
    local cx = math.floor(x / CELL_SIZE)
    local cy = math.floor(y / CELL_SIZE)
    local keys = {}
    for dx = -radius, radius do
        for dy = -radius, radius do
            keys[keyOf(cx + dx, cy + dy)] = true
        end
    end
    return keys
end

--- Every zone registered in a cell within `range` of (x, y), into `out` (wiped first): looked up cell by cell, so a
--- pass makes nothing.
---@param out table
---@return table
local function zonesNear(x, y, range, out)
    for k in pairs(out) do out[k] = nil end
    local radius = math.ceil(range / CELL_SIZE)
    local cx, cy = math.floor(x / CELL_SIZE), math.floor(y / CELL_SIZE)
    for dx = -radius, radius do
        for dy = -radius, radius do
            local bucket = zoneGrid[keyOf(cx + dx, cy + dy)]
            if bucket then
                for id in pairs(bucket) do
                    local zone = zones[id]
                    if zone then out[id] = zone end
                end
            end
        end
    end
    return out
end

-- Register zone into all cells it overlaps
local function registerZoneCells(zone)
    local cells = {}
    if zone.type == 'sphere' then
        local keys = getNearbyCellKeys(zone.pos.x, zone.pos.y, zone.radius)
        for key in pairs(keys) do cells[key] = true end
    elseif zone.type == 'box' then
        local half = math.max(zone.size.x, zone.size.y) / 2 + 1
        local keys = getNearbyCellKeys(zone.pos.x, zone.pos.y, half)
        for key in pairs(keys) do cells[key] = true end
    elseif zone.type == 'poly' then
        local rangeX = (zone._bbox.maxX - zone._bbox.minX) / 2 + CELL_SIZE
        local rangeY = (zone._bbox.maxY - zone._bbox.minY) / 2 + CELL_SIZE
        local cx = (zone._bbox.minX + zone._bbox.maxX) / 2
        local cy = (zone._bbox.minY + zone._bbox.maxY) / 2
        local keys = getNearbyCellKeys(cx, cy, math.max(rangeX, rangeY))
        for key in pairs(keys) do cells[key] = true end
    end
    zoneCells[zone.id] = cells
    for key in pairs(cells) do
        if not zoneGrid[key] then zoneGrid[key] = {} end
        zoneGrid[key][zone.id] = true
    end
end

-- Remove zone from grid
local function unregisterZoneCells(id)
    local cells = zoneCells[id]
    if cells then
        for key in pairs(cells) do
            if zoneGrid[key] then
                zoneGrid[key][id] = nil
                if not next(zoneGrid[key]) then zoneGrid[key] = nil end
            end
        end
    end
    zoneCells[id] = nil
end

-- ============================================
-- Containment Math
-- ============================================

-- Winding number algorithm for polygon containment
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
                local cross = (x2 - x1) * (py - y1) - (px - x1) * (y2 - y1)
                if cross > 0 then wn = wn + 1 end
            end
        else
            if y2 <= py then
                local cross = (x2 - x1) * (py - y1) - (px - x1) * (y2 - y1)
                if cross < 0 then wn = wn - 1 end
            end
        end
    end
    return wn
end

local function isPointInBox(zone, px, py, pz)
    local halfZ = zone.size.z / 2
    if pz < zone.pos.z - halfZ or pz > zone.pos.z + halfZ then return false end
    local dx = px - zone.pos.x
    local dy = py - zone.pos.y
    local lx = dx * zone._cosH + dy * zone._sinH
    local ly = -dx * zone._sinH + dy * zone._cosH
    return math.abs(lx) <= zone.size.x / 2 and math.abs(ly) <= zone.size.y / 2
end

local function isPointInSphere(zone, px, py, pz)
    local dx = px - zone.pos.x
    local dy = py - zone.pos.y
    local dz = pz - zone.pos.z
    return (dx * dx + dy * dy + dz * dz) <= zone._radiusSq
end

local function isPointInPoly(zone, px, py, pz)
    -- Quick bbox cull
    if px < zone._bbox.minX or px > zone._bbox.maxX then return false end
    if py < zone._bbox.minY or py > zone._bbox.maxY then return false end

    -- Z bounds are registration-time constants, precomputed in registerZone's poly branch.
    if zone._hasPerVertexZ then
        if pz < zone._effMinZ or pz > zone._effMaxZ then return false end
    else
        if zone.minZ and pz < zone.minZ then return false end
        if zone.maxZ and pz > zone.maxZ then return false end
    end
    return windingNumber(zone.points, px, py) ~= 0
end

local function isPointInZone(zone, px, py, pz)
    if zone.type == 'sphere' then return isPointInSphere(zone, px, py, pz)
    elseif zone.type == 'box'  then return isPointInBox(zone, px, py, pz)
    elseif zone.type == 'poly' then return isPointInPoly(zone, px, py, pz)
    end
    return false
end

-- ============================================
-- Zone Registration
-- ============================================

--- The id a zone gets when it names none.
---
--- Derived, not counted: satellites register from whip_core:onReady, which re-fires, so the same
--- registration must land on the same id and replace itself.
---
--- Letters, digits, _ and - only, at most 60: every client zone id is reported to the server as a
--- 'key' param, which refuses anything else (server/zones.lua, zoneRegistered).
---@param zType string
---@param data table
---@return string
local function autoId(zType, data)
    local p = data.pos or (type(data.points) == 'table' and data.points[1]) or {}
    local seed = ('%s|%s|%s|%.1f|%.1f|%.1f'):format(zType, tostring(data.group or ''), tostring(data.label or ''),
        tonumber(p.x or p[1]) or 0, tonumber(p.y or p[2]) or 0, tonumber(p.z or p[3]) or 0)
    local owner = (tostring(data._owner or CORE):gsub('[^%w_%-]', '')):sub(1, 40)
    return ('auto_%s_%08x'):format(owner, GetHashKey(seed) & 0xFFFFFFFF)
end

-- ============================================
-- Reporting a zone callback that threw
-- ============================================
--
-- Reported ONCE per zone per callback, then quiet (`inside` runs every tick and `condition` every
-- poll), as client/interact.lua's reportThrow does. Forgotten when the zone is removed or replaced,
-- so a fixed re-registration is judged fresh.
local zoneThrowReported = {}

--- Call one of a zone's callbacks. Answers what pcall answers.
---@param zone table
---@param what string  'onEnter' | 'onExit' | 'inside' | 'condition' | 'onVehicleEnter' | 'onVehicleExit'
local function callZone(zone, what, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then
        local key = tostring(zone.id) .. '|' .. what
        if not zoneThrowReported[key] then
            zoneThrowReported[key] = true
            print(('[whip_core:zones] %s for zone "%s" (%s) threw (reported once): %s')
                :format(what, tostring(zone.id), tostring(zone._owner or CORE), tostring(res)))
        end
    end
    return ok, res
end

local function forgetZoneThrows(id)
    local prefix = tostring(id) .. '|'
    for key in pairs(zoneThrowReported) do
        if key:sub(1, #prefix) == prefix then zoneThrowReported[key] = nil end
    end
end

--- A poly zone's containment Z bounds: whether any vertex carries its own heights, and the
--- effective range across them. Called on registration AND on every update.
---@param zone table
local function computePolyZ(zone)
    local hasPerVertexZ = false
    local effMinZ = zone.minZ or 999999
    local effMaxZ = zone.maxZ or -999999
    for _, pt in ipairs(zone.points or {}) do
        if pt.minZ or pt.maxZ then hasPerVertexZ = true end
        local vMin = pt.minZ or zone.minZ or effMinZ
        local vMax = pt.maxZ or zone.maxZ or effMaxZ
        if vMin < effMinZ then effMinZ = vMin end
        if vMax > effMaxZ then effMaxZ = vMax end
    end
    zone._hasPerVertexZ = hasPerVertexZ
    zone._effMinZ = effMinZ
    zone._effMaxZ = effMaxZ
end

-- ============================================
-- Telling the server (its mirror of client zones)
-- ============================================

--- What the server is told about a zone: its shape — never its callbacks or rules.
---@param zone table
---@return table
local function zoneReport(zone)
    return {
        type    = zone.type,
        pos     = zone.pos,
        size    = zone.size,
        heading = zone.heading,
        radius  = zone.radius,
        points  = zone.points,
        minZ    = zone.minZ,
        maxZ    = zone.maxZ,
        group   = zone.group,
        label   = zone.label,
    }
end

--- A moved or resized zone is reported again; the server takes the shape most reporters hold
--- (server/zones.lua, Zones.register). At most twice a second per zone, and always the LATEST shape.
local reportQueued = {}

-- ---- every report is PACED to the server's limit ----
--
-- zoneRegistered takes 20 a second with a burst of 100, per player, and a refused report is never
-- sent again. Sent here within a burst of 50 and one per 60 ms after it; a zone waiting its turn
-- sends its LATEST shape when the turn comes.
local REPORT_BURST, REPORT_EVERY_MS = 50, 60
local reportTokens, reportTokensAt = REPORT_BURST, 0
local reportOut, reportOutOrder, reportDraining = {}, {}, false

local function refillReportTokens()
    local now = GetGameTimer()
    if reportTokensAt == 0 then reportTokensAt = now end
    local gained = (now - reportTokensAt) // REPORT_EVERY_MS
    if gained > 0 then
        reportTokens = math.min(REPORT_BURST, reportTokens + gained)
        reportTokensAt = reportTokensAt + gained * REPORT_EVERY_MS
    end
end

local function sendReport(id)
    local zone = zones[id]
    if zone and not zone._dbZone then
        TriggerServerEvent('whip_core:server:zoneRegistered', id, zoneReport(zone))
    end
end

--- 'report' sends the zone's latest shape; 'remove' tells the server it is gone.
local function sendOne(id, op)
    if op == 'remove' then
        TriggerServerEvent('whip_core:server:zoneRemoved', id)
    else
        sendReport(id)
    end
end

--- Send a report or a removal within the server's limit. One entry per zone: a zone waiting its turn
--- sends what is true WHEN its turn comes (the latest shape, or its removal).
---
--- Removals too: a resource stopping removes all its zones in one loop, and a refused removal would
--- keep this player as a reporter of zones it no longer has.
---@param id string
---@param op 'report'|'remove'
local function pace(id, op)
    refillReportTokens()
    if reportTokens >= 1 and not reportDraining then
        reportTokens = reportTokens - 1
        sendOne(id, op)
        return
    end
    local queued = reportOut[id] ~= nil
    reportOut[id] = op
    if not queued then reportOutOrder[#reportOutOrder + 1] = id end
    if reportDraining then return end
    reportDraining = true
    CreateThread(function()
        local i = 1
        while i <= #reportOutOrder do
            refillReportTokens()
            if reportTokens >= 1 then
                reportTokens = reportTokens - 1
                local nextId = reportOutOrder[i]
                local nextOp = reportOut[nextId]
                reportOut[nextId] = nil
                if nextOp then sendOne(nextId, nextOp) end
                i = i + 1
            else
                Wait(REPORT_EVERY_MS)
            end
        end
        reportOutOrder = {}
        reportDraining = false
    end)
end

--- The key rule the server holds a reported zone to (letters, digits, _ and -, 60 at most).
local function serverTakesId(id)
    return type(id) == 'string' and #id <= 60 and not id:find('[^%w_%-]')
end

---@param id string
local function reportZone(id)
    -- Not an id the server refuses: each would be a recorded rejection.
    if not serverTakesId(id) then return end
    pace(id, 'report')
end

---@param id string
local function queueReport(id)
    if reportQueued[id] then return end
    reportQueued[id] = true
    SetTimeout(500, function()
        reportQueued[id] = nil
        reportZone(id)
    end)
end

local function registerZone(zType, data)
    local id = data.id or autoId(zType, data)

    -- Another resource's zone is not yours to take: refused while that owner runs (a stopped
    -- owner's zones are gone already, the onResourceStop sweep).
    local held = zones[id]
    if held and (held._owner or CORE) ~= (data._owner or CORE) and Registry.alive(held._owner or CORE) then
        return false, ('zone "%s" belongs to %s'):format(tostring(id), held._owner or CORE)
    end

    local zone = {
        id             = id,
        type           = zType,
        pos            = data.pos or vector3(0, 0, 0),
        -- Callbacks
        onEnter        = data.onEnter,
        onExit         = data.onExit,
        inside         = data.inside,
        onVehicleEnter = data.onVehicleEnter,
        onVehicleExit  = data.onVehicleExit,
        -- Behavior
        condition      = data.condition,
        priority       = data.priority or 0,
        group          = data.group,
        debug          = data.debug or false,
        -- Defaults on only when the zone declares a vehicle callback (the sweep walks the
        -- vehicle pool every 2s); an explicit true/false always wins.
        trackVehicles  = data.trackVehicles == true
            or (data.trackVehicles == nil
                and (data.onVehicleEnter ~= nil or data.onVehicleExit ~= nil)),
        label          = data.label or id,
        -- Rules engine
        rules          = data.rules or nil,
        notify         = data.notify or false,
        -- Local weather/time for anyone standing in this zone. A string is shorthand for
        -- `{ weather = '...' }`; a table takes the full layer shape. Applied on enter and
        -- removed on exit under a layer named after the zone, so leaving a foggy swamp
        -- restores whatever was underneath instead of clearing every effect on the player.
        weather        = data.weather or nil,
        -- Internal
        _owner         = data._owner,
        _dbZone        = data._dbZone or false,
    }

    if zType == 'box' then
        zone.size    = data.size or vector3(10, 10, 5)
        zone.heading = data.heading or 0.0
        local rad    = math.rad(zone.heading)
        zone._cosH   = math.cos(rad)
        zone._sinH   = math.sin(rad)
        -- Bounding box for grid
        local half = math.max(zone.size.x, zone.size.y) / 2
        zone._bbox = {
            minX = zone.pos.x - half, maxX = zone.pos.x + half,
            minY = zone.pos.y - half, maxY = zone.pos.y + half,
        }
    elseif zType == 'sphere' then
        zone.radius    = data.radius or 10.0
        zone._radiusSq = zone.radius * zone.radius
        zone._bbox = {
            minX = zone.pos.x - zone.radius, maxX = zone.pos.x + zone.radius,
            minY = zone.pos.y - zone.radius, maxY = zone.pos.y + zone.radius,
        }
    elseif zType == 'poly' then
        zone.points = data.points or {}
        zone.minZ   = data.minZ
        zone.maxZ   = data.maxZ
        -- Compute bounding box + centroid
        local minX, maxX = math.huge, -math.huge
        local minY, maxY = math.huge, -math.huge
        local sumX, sumY = 0, 0
        for _, p in ipairs(zone.points) do
            local px = p.x or p[1]
            local py = p.y or p[2]
            if px < minX then minX = px end
            if px > maxX then maxX = px end
            if py < minY then minY = py end
            if py > maxY then maxY = py end
            sumX = sumX + px
            sumY = sumY + py
        end
        zone._bbox = { minX = minX, maxX = maxX, minY = minY, maxY = maxY }
        if #zone.points > 0 then
            zone.pos = vector3(sumX / #zone.points, sumY / #zone.points, (zone.minZ or 0) + ((zone.maxZ or 0) - (zone.minZ or 0)) / 2)
        end

        -- Containment-test Z bounds, derived ONCE (isPointInPoly reads these).
        computePolyZ(zone)
    end

    -- A zone registered again replaces the old one cleanly: its grid cells unhooked, and its rules
    -- off a player standing in it (as a new rules table from UpdateZone does). The enforcement loop applies the new ones,
    -- and the poll decides whether they are still inside (no fake exit and re-enter).
    if held then
        unregisterZoneCells(id)
        removeDebugBlips(id)
        forgetZoneThrows(id)
        if insideZones[id] then
            revertZoneRules(held, insideZones)
            clearZoneWeather(held)
        end
    end

    zones[id] = zone
    registerZoneCells(zone)
    if held and insideZones[id] then applyZoneWeather(zone) end
    if zone.debug then startDebugDraw() end

    -- Sync to server for server-side validation, but NOT for a zone the server just pushed to us
    -- via zonesSync (an echo). The server keeps the shape most reporters hold (server/zones.lua); a
    -- zone the server has to trust belongs in the server's RegisterZone / EnsureZone. An id the server's
    -- key rule refuses never reaches it: said here, once, because the server's refusal is silent to
    -- the resource that made the zone.
    if not zone._dbZone and (type(id) ~= 'string' or #id > 60 or id:find('[^%w_%-]')) then
        print(('[whip_core:zones] zone "%s" works on this client, but the server will not know it: a zone id '
            .. 'is letters, digits, _ and - only, 60 at most'):format(tostring(id)))
    end
    if not zone._dbZone then
        reportZone(id)   -- paced
    end

    return id
end

-- ============================================
-- Zone Removal
-- ============================================

--- Switch the ped's COLLISION proof on or off, leaving its seven other proofs as they are. Being
--- collision-proof is what stops fall damage (noFallDamage); it also stops damage from crashing or
--- being run over while inside. Only the one proof, read back first: client/death.lua sets every
--- proof while a player is downed, and a zone must not switch those off on its way out.
---@param ped number
---@param on boolean
local function setCollisionProof(ped, on)
    local function yes(v) return v == true or v == 1 end
    local _, bullet, fire, explosion, collision, melee, steam, p7, drown = GetEntityProofs(ped)
    if yes(collision) == on then return end
    SetEntityProofs(ped, yes(bullet), yes(fire), yes(explosion), on, yes(melee), yes(steam), yes(p7), yes(drown))
end

--- [vehicle] = true: every car a zone's speedLimit has capped on this game (the rules loop below).
local cappedVehicles = {}

--- Every capped car put back, not only the one being sat in: a zone deleted or edited while the player stands in
--- it on foot would otherwise leave a car capped for good.
local function uncapAll()
    for veh in pairs(cappedVehicles) do
        if DoesEntityExist(veh) then SetVehicleMaxSpeed(veh, 0.0) end
        cappedVehicles[veh] = nil
    end
end

--- Undo what a zone's rules did to the player, when they stop applying to them: they left, the zone
--- was removed, or its rules were replaced while they stood in it. An effect another zone the player
--- is still in also applies is left on.
---@param zone table
---@param stillInside table  [zoneId] = true for the zones the player is still inside
function revertZoneRules(zone, stillInside)   -- the local forward-declared at the top
    local rules = zone and zone.rules
    if not rules or not next(rules) then return end

    local function stillApplied(key)
        for otherId in pairs(stillInside) do
            local other = zones[otherId]
            if otherId ~= zone.id and other and other.rules and other.rules[key] then return true end
        end
        return false
    end

    local ped = PlayerPedId()
    -- Its own hold only (client/ped_hold.lua): a downed player stays invincible under death's.
    if rules.noPvP and not stillApplied('noPvP') then PedHold.release('zoneNoPvP') end
    -- Not while downed: death.lua holds every proof on until the revive (see setCollisionProof).
    if rules.noFallDamage and not stillApplied('noFallDamage') and not PlayerIsDead then
        setCollisionProof(ped, false)
    end
    if rules.speedLimit and not stillApplied('speedLimit') then uncapAll() end
end

local function removeZone(id)
    if not zones[id] then return end
    -- Fire onExit if player was inside
    if insideZones[id] then
        local zone = zones[id]
        revertZoneRules(zone, insideZones)
        clearZoneWeather(zone)
        if zone.onExit then callZone(zone, 'onExit', zone.onExit, zone) end
        insideZones[id] = nil
    end
    local wasReported = not zones[id]._dbZone and serverTakesId(id)
    unregisterZoneCells(id)
    removeDebugBlips(id)
    forgetZoneThrows(id)
    zones[id] = nil
    -- Paced like the reports, and only for a zone the server could have been told about.
    if wasReported then pace(id, 'remove') end
end

-- ============================================
-- Zone-local weather
-- ============================================
--
-- A zone declaring `weather` gives everyone inside it their own sky. It is a LAYER named after
-- the zone, which is what makes overlapping effects behave: a mission storm can sit on top of
-- a zone's fog, and when the mission ends the fog comes back rather than the player being
-- dumped straight to server weather.
--
-- Priority defaults just above the zone's own so that overlapping zones resolve the same way
-- their rules do — the more important zone wins its weather too.

local function zoneWeatherLayer(zone)
    return 'zone:' .. tostring(zone.id)
end

function applyZoneWeather(zone)
    if not zone.weather or not WeatherLayer then return end
    local opts
    if type(zone.weather) == 'table' then
        opts = {}
        for k, v in pairs(zone.weather) do opts[k] = v end
    else
        opts = { weather = zone.weather }
    end
    if opts.priority == nil then opts.priority = 10 + (zone.priority or 0) end
    WeatherLayer.set(zoneWeatherLayer(zone), opts)
end

function clearZoneWeather(zone)
    if not zone.weather or not WeatherLayer then return end
    WeatherLayer.set(zoneWeatherLayer(zone), nil)
end

--- Remove every one of `owner`'s zones in a group.
---
--- Only the owner's, and never "no group".
---@param group string
---@param owner string|nil  nil is whip_core (the export passes the caller)
---@return boolean ok
---@return number|string countOrReason
local function removeGroup(group, owner)
    if type(group) ~= 'string' or group == '' then return false, 'a group name is required' end
    owner = owner or CORE
    local toRemove = {}
    for id, zone in pairs(zones) do
        if zone.group == group and (zone._owner or CORE) == owner then toRemove[#toRemove + 1] = id end
    end
    for _, id in ipairs(toRemove) do removeZone(id) end
    return true, #toRemove
end

--- Remove one of `owner`'s zones. Only their own.
---@return boolean ok
---@return string|nil reason
local function removeOwnZone(id, owner)
    local zone = zones[id]
    if not zone then return false, ('no zone "%s"'):format(tostring(id)) end
    if (zone._owner or CORE) ~= owner then
        return false, ('zone "%s" belongs to %s'):format(tostring(id), zone._owner or CORE)
    end
    removeZone(id)
    return true
end

-- ============================================
-- Zone Updates
-- ============================================

local function updatePosition(id, pos)
    local zone = zones[id]
    if not zone then return end
    -- Unregister from old cells
    unregisterZoneCells(id)

    -- A poly moves by moving its points: its `pos` is only the centroid, and containment reads the
    -- points and the bbox. The whole shape is shifted by how far the centroid moves, heights
    -- included, and its bounds are rebuilt.
    if zone.type == 'poly' then
        local old = zone.pos or vector3(0, 0, 0)
        local dx, dy, dz = pos.x - old.x, pos.y - old.y, (pos.z or old.z) - old.z
        local moved = {}
        local minX, maxX = math.huge, -math.huge
        local minY, maxY = math.huge, -math.huge
        for i, p in ipairs(zone.points or {}) do
            local nx = (p.x or p[1]) + dx
            local ny = (p.y or p[2]) + dy
            moved[i] = {
                x = nx, y = ny,
                minZ = p.minZ and (p.minZ + dz) or nil,
                maxZ = p.maxZ and (p.maxZ + dz) or nil,
            }
            if nx < minX then minX = nx end
            if nx > maxX then maxX = nx end
            if ny < minY then minY = ny end
            if ny > maxY then maxY = ny end
        end
        zone.points = moved
        if zone.minZ then zone.minZ = zone.minZ + dz end
        if zone.maxZ then zone.maxZ = zone.maxZ + dz end
        -- No points, no bounds to rebuild: an infinite bbox would send the cell walk below
        -- off to infinity.
        if #moved > 0 then
            zone._bbox = { minX = minX, maxX = maxX, minY = minY, maxY = maxY }
        end
        computePolyZ(zone)
    end

    -- Update position
    zone.pos = pos
    -- Recompute bbox
    if zone.type == 'sphere' then
        zone._bbox = {
            minX = pos.x - zone.radius, maxX = pos.x + zone.radius,
            minY = pos.y - zone.radius, maxY = pos.y + zone.radius,
        }
    elseif zone.type == 'box' then
        local half = math.max(zone.size.x, zone.size.y) / 2
        zone._bbox = {
            minX = pos.x - half, maxX = pos.x + half,
            minY = pos.y - half, maxY = pos.y + half,
        }
    end
    -- Re-register in new cells
    registerZoneCells(zone)
    queueReport(id)   -- and tell the server where it went
end

local function updateSize(id, size)
    local zone = zones[id]
    if not zone then return end

    -- A poly has no 'size' (its shape is its points): refuse loudly rather than do nothing.
    if zone.type == 'poly' then
        print(('[whip_core:zones] updateSize ignored for poly zone "%s" — a poly is resized by editing its points'):format(tostring(id)))
        return false, 'a poly zone is resized by editing its points'
    end

    -- The new size is read, and checked, BEFORE the zone leaves the grid: a throw after would leave
    -- it in `zones` but in no cell. A box takes a vector3; a sphere a number (or a vector whose x is
    -- the radius).
    local radius
    if zone.type == 'box' then
        local ok = type(size) ~= 'number' and pcall(function() return size.x + size.y + size.z end)
        if not ok then
            print(('[whip_core:zones] updateSize ignored for box zone "%s" — a box takes a vector3'):format(tostring(id)))
            return false, 'a box zone takes a vector3 size'
        end
    else
        if type(size) == 'number' then
            radius = size
        else
            local okX, x = pcall(function() return size.x end)
            radius = okX and tonumber(x) or nil
        end
        if not radius or radius <= 0 then
            print(('[whip_core:zones] updateSize ignored for sphere zone "%s" — a sphere takes a radius'):format(tostring(id)))
            return false, 'a sphere zone takes a radius (a number above 0)'
        end
    end

    unregisterZoneCells(id)
    if zone.type == 'box' then
        zone.size = size
        local half = math.max(size.x, size.y) / 2
        zone._bbox = {
            minX = zone.pos.x - half, maxX = zone.pos.x + half,
            minY = zone.pos.y - half, maxY = zone.pos.y + half,
        }
    elseif zone.type == 'sphere' then
        zone.radius = radius
        zone._radiusSq = zone.radius * zone.radius
        zone._bbox = {
            minX = zone.pos.x - zone.radius, maxX = zone.pos.x + zone.radius,
            minY = zone.pos.y - zone.radius, maxY = zone.pos.y + zone.radius,
        }
    end
    registerZoneCells(zone)
    queueReport(id)   -- and tell the server its new size
    return true
end

local function checkContains(id, point)
    local zone = zones[zoneIdOf(id)]
    if not zone or point == nil then return false end
    return isPointInZone(zone, point.x, point.y, point.z)
end

-- ============================================
-- Main Polling Thread (single thread, all zones)
-- ============================================

CreateThread(function()

    --- Reused scratch, all four (the candidate set, the inside set, the two diff lists), wiped each
    --- pass. None of them outlive a pass: `insideZones` carries state between ticks, and it must stay
    --- a SEPARATE table (see the copy at the bottom of the loop).
    local candidates = {}
    local nowInside  = {}
    local entering   = {}
    local exiting    = {}

    --- One pass of the poll. A FUNCTION so that each pass runs under pcall — see the loop at the end.
    local function tick()
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local px, py, pz = pos.x, pos.y, pos.z

        if next(zones) then
            -- The zones in the cells round the player, from the spatial grid
            zonesNear(px, py, Config.ZoneCheckRange or 200, candidates)

            for k in pairs(nowInside) do nowInside[k] = nil end

            for id, zone in pairs(candidates) do
                -- Skip if condition function returns false
                if zone.condition then
                    local ok, result = callZone(zone, 'condition', zone.condition)
                    if not ok or not result then goto continue end
                end

                if isPointInZone(zone, px, py, pz) then
                    nowInside[id] = true
                end
                ::continue::
            end

            -- Diff: find enters and exits.
            --
            -- Cleared as ARRAYS — a numeric wipe rather than a pairs walk, because both are
            -- appended to with #t + 1 below and a stale tail would make table.sort and the ipairs
            -- that follow it see last tick's zones.
            for i = #entering, 1, -1 do entering[i] = nil end
            for i = #exiting,  1, -1 do exiting[i]  = nil end

            for id in pairs(nowInside) do
                if not insideZones[id] then
                    entering[#entering + 1] = zones[id]
                end
            end
            for id in pairs(insideZones) do
                if not nowInside[id] and zones[id] then
                    exiting[#exiting + 1] = zones[id]
                end
            end

            -- Sort: exits fire lowest priority first, enters fire highest priority first
            if #exiting > 1 then
                table.sort(exiting, function(a, b) return (a.priority or 0) < (b.priority or 0) end)
            end
            if #entering > 1 then
                table.sort(entering, function(a, b) return (a.priority or 0) > (b.priority or 0) end)
            end

            -- Fire onExit + revert rules (against the zones the player is in NOW, so two zones left
            -- in the same tick do not each keep the other's effect on)
            for _, zone in ipairs(exiting) do
                revertZoneRules(zone, nowInside)
                -- Notify on exit (independent of rules)
                if zone.notify then
                    local msg = (zone.rules and zone.rules.exitNotify) or ('Left ' .. (zone.label or 'zone'))
                    UI.Notify(msg, 'warning', 2000)
                end
                clearZoneWeather(zone)
                if zone.onExit then callZone(zone, 'onExit', zone.onExit, zone) end
                -- Fire global event for other resources (whip_core:zone:exited)
                WhipEmit('whip_core:zone:exited', zoneEventPayload(zone))
            end

            -- Fire onEnter + apply one-time rules
            for _, zone in ipairs(entering) do
                -- Notify on enter (independent of rules)
                if zone.notify then
                    local msg = (zone.rules and zone.rules.enterNotify) or ('Entered ' .. (zone.label or 'zone'))
                    UI.Notify(msg, 'info', 2000)
                end
                if zone.rules and next(zone.rules) then
                    local rules = zone.rules
                    local myPed = PlayerPedId()
                    if rules.noWeapons then
                        RemoveAllPedWeapons(myPed, true)
                    end
                    -- Authorization check + eject, in its own thread: the ACE check is a server round
                    -- trip, and inline it would stall every other zone's enter and exit.
                    local hasWhitelist = rules.jobWhitelist or rules.aceWhitelist or rules.charWhitelist
                    if hasWhitelist and rules.ejectUnauthorized then CreateThread(function()
                        local allowed = false

                        -- Job whitelist
                        if rules.jobWhitelist and not allowed then
                            local playerJobs = GetPlayerJobs()
                            for _, jobKey in ipairs(rules.jobWhitelist) do
                                for _, pJob in pairs(playerJobs) do
                                    if pJob.key == jobKey then allowed = true; break end
                                end
                                if allowed then break end
                            end
                        end

                        -- ACE permission whitelist (checked via server callback)
                        --
                        -- Only a real "no" ejects: the server's answer is a bare true or false; a refusal
                        -- by the gate ('Rate limited') or a lost request comes with a reason. Asked again
                        -- a few times; with still no answer the player is let be (this rule is kept by
                        -- their own game anyway).
                        if rules.aceWhitelist and not allowed then
                            local hasAce, why
                            for attempt = 1, 3 do
                                hasAce, why = Callback('whip_core:checkAcePermission', rules.aceWhitelist)
                                if why == nil then break end
                                Wait(1000 * attempt)
                            end
                            if hasAce or why ~= nil then allowed = true end
                        end

                        -- Character ID whitelist
                        if rules.charWhitelist and not allowed then
                            local myCharId = PlayerData.charId
                            if myCharId then
                                for _, cid in ipairs(rules.charWhitelist) do
                                    if cid == myCharId then allowed = true; break end
                                end
                            end
                        end

                        -- Still inside once the answer is in: someone who has already walked back out
                        -- has nothing to be ejected from.
                        if not allowed and insideZones[zone.id] then
                            UI.Notify('You are not authorized in this area', 'error', 3000)
                            ejectFromZone(zone)
                        end
                    end) end
                end
                applyZoneWeather(zone)
                if zone.onEnter then callZone(zone, 'onEnter', zone.onEnter, zone) end
                -- Fire global event for other resources (whip_core:zone:entered)
                WhipEmit('whip_core:zone:entered', zoneEventPayload(zone))
            end

            -- Update state: COPIED, never handed over. nowInside is reused scratch; aliasing the two
            -- (`insideZones = nowInside`) would make the next wipe clear both, and every enter and
            -- exit would silently stop firing while "am I in it" still answered right.
            for id in pairs(insideZones) do
                if not nowInside[id] then insideZones[id] = nil end
            end
            for id in pairs(nowInside) do insideZones[id] = true end

            -- Fire inside callbacks
            for id in pairs(insideZones) do
                local zone = zones[id]
                if zone and zone.inside then
                    callZone(zone, 'inside', zone.inside, zone)
                end
            end
        end
    end

    -- Each pass under pcall: a zone with bad data (a satellite's malformed shape) must not end the
    -- poll for the session. A failing pass is reported (the first few times) and the poll carries on.
    local failures = 0
    while true do
        local cost = WhipCost.start()
        local ok, err = pcall(tick)
        WhipCost.stop('zones: the zone poll (enter, exit, inside)', cost)
        if not ok then
            failures = failures + 1
            if failures <= 3 then
                print(('[whip_core:zones] ERROR in the zone poll (it keeps running): %s'):format(tostring(err)))
            end
        end
        -- Read each time round, so a change in /whip → Settings takes effect from the next poll.
        Wait(Config.ZonePollInterval or 300)
    end
end)

-- ============================================
-- Rules Engine — Eject Logic
-- ============================================

ejectFromZone = function(zone)
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local bestPos = pos
    local bestDist = 999
    for angle = 0, 360, 15 do
        local rad = math.rad(angle)
        for dist = 5, 100, 5 do
            local testX = pos.x + math.cos(rad) * dist
            local testY = pos.y + math.sin(rad) * dist
            if not isPointInZone(zone, testX, testY, pos.z) then
                if dist < bestDist then
                    bestDist = dist
                    bestPos = vector3(testX, testY, pos.z)
                end
                break
            end
        end
    end
    SetEntityCoords(ped, bestPos.x, bestPos.y, bestPos.z, false, false, false, false)
end

-- ============================================
-- Rules Engine — Per-Frame Enforcement
-- ============================================

-- noCollision's list of other players' peds, refreshed twice a second rather than built on every
-- pass. GetActivePlayers is the players already.
local COLLISION_LIST_MS = 500
local collisionPeds, collisionListAt = {}, 0

-- ---- the frame-rate rules: the 'zoneRules' control block ----
--
-- No melee / no PvP hold attack and melee off; no firing / no PvP and no weapons are one-frame natives,
-- run by the block's per-frame hook. Worked out on each pass below and handed to the block only when
-- they change, so this thread itself never needs frame rate.
local zoneFrame = { melee = false, firing = false, unarm = false }

local function zoneRulesFrame()
    if zoneFrame.firing then DisablePlayerFiring(PlayerId(), true) end
    if zoneFrame.unarm then
        -- Only when a weapon is out: this runs every frame.
        local ped = PlayerPedId()
        if GetSelectedPedWeapon(ped) ~= `WEAPON_UNARMED` then
            SetCurrentPedWeapon(ped, `WEAPON_UNARMED`, true)
        end
    end
end

local function setZoneFrame(melee, firing, unarm)
    if zoneFrame.melee == melee and zoneFrame.firing == firing and zoneFrame.unarm == unarm then return end
    zoneFrame.melee, zoneFrame.firing, zoneFrame.unarm = melee, firing, unarm
    if not (melee or firing or unarm) then ControlBlocks.release('zoneRules') return end
    ControlBlocks.hold('zoneRules', { controls = melee and { 24, 257, 140, 141, 142 } or {} }, zoneRulesFrame)
end

CreateThread(function()
    while true do
        local hasRules  = false
        local melee, firing, unarm = false, false, false
        local noPvP = false   -- invincible: the 'zoneNoPvP' ped hold, set after the pass when it changes
        -- One pass, caught: a bad rule value must not kill this thread (and leave the frame-rate rules'
        -- block on). (The pass keeps the indentation it had.)
        local passOk, passErr = pcall(function()
        local ped = PlayerPedId()
        -- The speed limit is one zone's, by priority: the rules below are restrictions that hold together, but
        -- speed limits can disagree (a car park's 20 inside a district's 60). The highest-priority zone that sets
        -- one decides (two at the same priority: the lower).
        local limitAt, limitPrio = nil, nil

        for id in pairs(insideZones) do
            local zone = zones[id]
            if not zone or not zone.rules then goto nextRule end
            local rules = zone.rules

            -- Only rules THIS loop enforces count (`heal` is the 300ms thread's below).
            local enforced = rules.disableFiring or rules.noWeapons or rules.noMelee
                or rules.noPvP or rules.noVehicles or rules.speedLimit
                or rules.noWantedLevel or rules.noFallDamage or rules.noCollision
            if not enforced then goto nextRule end
            hasRules = true

            -- No PvP works both ways: invincible, and nobody inside fires or swings (or they could hit
            -- people outside who cannot hit back). Held by the 'zoneRules' block, above.
            if rules.disableFiring or rules.noPvP then firing = true end
            if rules.noWeapons then unarm = true end
            if rules.noMelee or rules.noPvP then melee = true end
            if rules.noPvP then noPvP = true end
            if rules.noVehicles then
                if IsPedInAnyVehicle(ped, false) then
                    TaskLeaveVehicle(ped, GetVehiclePedIsIn(ped, false), 4160)
                end
            end
            local lim = tonumber(rules.speedLimit)
            if lim then
                local p = tonumber(zone.priority) or 0
                if limitAt == nil or p > limitPrio or (p == limitPrio and lim < limitAt) then
                    limitAt, limitPrio = lim, p
                end
            end
            if rules.noWantedLevel then
                if GetPlayerWantedLevel(PlayerId()) > 0 then
                    ClearPlayerWantedLevel(PlayerId())
                end
            end
            if rules.noFallDamage then
                setCollisionProof(ped, true)   -- a no-op once on; see its note
            end
            if rules.noCollision then
                local now = GetGameTimer()
                if now >= collisionListAt then
                    collisionListAt = now + COLLISION_LIST_MS
                    collisionPeds = {}
                    local me = PlayerId()
                    for _, pid in ipairs(GetActivePlayers()) do
                        if pid ~= me then collisionPeds[#collisionPeds + 1] = GetPlayerPed(pid) end
                    end
                end
                for i = 1, #collisionPeds do
                    SetEntityNoCollisionEntity(ped, collisionPeds[i], true)
                end
            end

            ::nextRule::
        end
        if limitAt then
            local veh = GetVehiclePedIsIn(ped, false)
            if veh ~= 0 then
                SetVehicleMaxSpeed(veh, limitAt / 3.6)
                cappedVehicles[veh] = true   -- put back by uncapAll, wherever the car is by then
            end
        end
        end)
        if not passOk then
            print(('[whip_core:zones] a rules pass failed: %s'):format(tostring(passErr)))
            melee, firing, unarm, noPvP = false, false, false, false
        end
        setZoneFrame(melee, firing, unarm)
        if noPvP ~= PedHold.held('zoneNoPvP') then
            PedHold.set('zoneNoPvP', noPvP and { invincible = true } or nil)
        end

        -- Two speeds: a quarter second for the rules that need to keep winning (invincibility, speed
        -- caps, wanted level, collision — including noCollision's ped-pool walk), and a slow idle when
        -- nothing applies. The frame-rate rules are the 'zoneRules' block's, above.
        if hasRules then
            Wait(250)
        else
            Wait(1000)
        end
    end
end)

-- ============================================
-- Rules Engine — Heal Thread (slower tick)
-- ============================================

CreateThread(function()
    while true do
        for id in pairs(insideZones) do
            local zone = zones[id]
            if zone and zone.rules and zone.rules.heal then
                local ped = PlayerPedId()
                local health = GetEntityHealth(ped)
                local max = 200
                local rate = zone.rules.healRate or 2
                if health < max and health > 0 then
                    SetEntityHealth(ped, math.min(max, health + rate))
                end
            end
        end
        Wait(300)
    end
end)

-- ============================================
-- Vehicle Tracking Thread
-- ============================================

--- Worth sweeping the vehicle pool for? Only when something LISTENS: the enter/exit callbacks are
--- the only readers of this thread's result.
local function tracksVehicles(zone)
    return zone.trackVehicles and (zone.onVehicleEnter ~= nil or zone.onVehicleExit ~= nil)
end

CreateThread(function()
    local vehicleZoneState = {}

    while true do
        -- Check if any zone has tracking enabled
        local hasTracking = false
        for _, zone in pairs(zones) do
            if tracksVehicles(zone) then hasTracking = true; break end
        end

        -- A zone that was removed (or stopped listening) takes its membership with it.
        for id in pairs(vehicleZoneState) do
            if not zones[id] or not tracksVehicles(zones[id]) then vehicleZoneState[id] = nil end
        end

        if not hasTracking then
            Wait(5000)
            goto nextTick
        end

        local vehicles = GetGamePool('CVehicle')

        for id, zone in pairs(zones) do
            if not tracksVehicles(zone) then goto nextZone end
            if not vehicleZoneState[id] then vehicleZoneState[id] = {} end

            local nowInside = {}
            for _, veh in ipairs(vehicles) do
                if DoesEntityExist(veh) then
                    local vPos = GetEntityCoords(veh)
                    if isPointInZone(zone, vPos.x, vPos.y, vPos.z) then
                        nowInside[veh] = true
                    end
                end
            end

            -- Diff: vehicle enters
            for veh in pairs(nowInside) do
                if not vehicleZoneState[id][veh] then
                    local plate = GetVehicleNumberPlateText(veh) or ''
                    if zone.onVehicleEnter then callZone(zone, 'onVehicleEnter', zone.onVehicleEnter, veh, plate, zone) end
                end
            end
            -- Diff: vehicle exits
            for veh in pairs(vehicleZoneState[id]) do
                if not nowInside[veh] then
                    local plate = DoesEntityExist(veh) and GetVehicleNumberPlateText(veh) or ''
                    if zone.onVehicleExit then callZone(zone, 'onVehicleExit', zone.onVehicleExit, veh, plate, zone) end
                end
            end

            vehicleZoneState[id] = nowInside
            ::nextZone::
        end

        -- Read each time round, so a change in /whip → Settings takes effect from the next poll.
        Wait(Config.ZoneVehiclePollInterval or 2000)
        ::nextTick::
    end
end)

-- ============================================
-- Debug Render Thread
-- ============================================

-- Draw a solid wall between two points at minZ→maxZ
local function drawWall(x1, y1, x2, y2, minZ, maxZ, r, g, b, a)
    -- Two triangles make a quad wall
    DrawPoly(x1, y1, minZ, x2, y2, minZ, x1, y1, maxZ, r, g, b, a)
    DrawPoly(x2, y2, minZ, x2, y2, maxZ, x1, y1, maxZ, r, g, b, a)
    -- Reverse winding (visible from both sides)
    DrawPoly(x1, y1, maxZ, x2, y2, minZ, x1, y1, minZ, r, g, b, a)
    DrawPoly(x1, y1, maxZ, x2, y2, maxZ, x2, y2, minZ, r, g, b, a)
end

-- Draw a wall with per-vertex Z heights (for variable-height poly zones)
local function drawWallVarZ(x1, y1, min1, max1, x2, y2, min2, max2, r, g, b, a)
    DrawPoly(x1, y1, min1, x2, y2, min2, x1, y1, max1, r, g, b, a)
    DrawPoly(x2, y2, min2, x2, y2, max2, x1, y1, max1, r, g, b, a)
    DrawPoly(x1, y1, max1, x2, y2, min2, x1, y1, min1, r, g, b, a)
    DrawPoly(x1, y1, max1, x2, y2, max2, x2, y2, min2, r, g, b, a)
end

--- A box's walls and edges, in any colour. Zones and ZonePreview both draw through this.
---@param p table  centre {x,y,z}
---@param s table  size {x,y,z}
---@param h number heading, degrees
local function drawBoxShape(p, s, h, r, g, b, a, er, eg, eb)
    local rad = math.rad(h or 0)
    local cosH, sinH = math.cos(rad), math.sin(rad)
    local halfX, halfY, halfZ = s.x / 2, s.y / 2, s.z / 2

    local corners = {}
    for _, off in ipairs({ {-halfX, -halfY}, {halfX, -halfY}, {halfX, halfY}, {-halfX, halfY} }) do
        corners[#corners + 1] = {
            x = off[1] * cosH - off[2] * sinH + p.x,
            y = off[1] * sinH + off[2] * cosH + p.y,
        }
    end

    local botZ = p.z - halfZ
    local topZ = p.z + halfZ

    -- 4 solid walls
    for i = 1, 4 do
        local j = (i % 4) + 1
        drawWall(corners[i].x, corners[i].y, corners[j].x, corners[j].y, botZ, topZ, r, g, b, a)
    end
    -- Edge lines for clarity
    for i = 1, 4 do
        local j = (i % 4) + 1
        DrawLine(corners[i].x, corners[i].y, botZ, corners[j].x, corners[j].y, botZ, er, eg, eb, 200)
        DrawLine(corners[i].x, corners[i].y, topZ, corners[j].x, corners[j].y, topZ, er, eg, eb, 200)
        DrawLine(corners[i].x, corners[i].y, botZ, corners[i].x, corners[i].y, topZ, er, eg, eb, 150)
    end
end

local function drawBoxZone(zone)
    local r, g, b, a = 0, 100, 255, 50
    if insideZones[zone.id] then r, g, b = 0, 200, 80 end
    drawBoxShape(zone.pos, zone.size, zone.heading or 0, r, g, b, a, r, g + 100, b)
end

-- Precomputed sphere mesh (unit sphere vertices, generated once)
local _sphereMesh = nil

local function buildSphereMesh(segments, rings)
    segments = segments or 10
    rings = rings or 8
    local mesh = {} -- array of { x1,y1,z1, x2,y2,z2, x3,y3,z3 } triangles
    for i = 0, rings - 1 do
        local lat0 = math.pi * (i / rings - 0.5)
        local lat1 = math.pi * ((i + 1) / rings - 0.5)
        local cosLat0, sinLat0 = math.cos(lat0), math.sin(lat0)
        local cosLat1, sinLat1 = math.cos(lat1), math.sin(lat1)
        for j = 0, segments - 1 do
            local lon0 = 2 * math.pi * (j / segments)
            local lon1 = 2 * math.pi * ((j + 1) / segments)
            local cosLon0, sinLon0 = math.cos(lon0), math.sin(lon0)
            local cosLon1, sinLon1 = math.cos(lon1), math.sin(lon1)
            -- 4 vertices of this quad
            local x00 = cosLat0 * cosLon0
            local y00 = cosLat0 * sinLon0
            local z00 = sinLat0
            local x10 = cosLat1 * cosLon0
            local y10 = cosLat1 * sinLon0
            local z10 = sinLat1
            local x01 = cosLat0 * cosLon1
            local y01 = cosLat0 * sinLon1
            local z01 = sinLat0
            local x11 = cosLat1 * cosLon1
            local y11 = cosLat1 * sinLon1
            local z11 = sinLat1
            -- Two triangles per quad
            mesh[#mesh + 1] = { x00, y00, z00, x10, y10, z10, x01, y01, z01 }
            mesh[#mesh + 1] = { x10, y10, z10, x11, y11, z11, x01, y01, z01 }
        end
    end
    return mesh
end

local function drawSphereZone(zone)
    if not _sphereMesh then _sphereMesh = buildSphereMesh(10, 8) end
    local r, g, b, a = 0, 100, 255, 30
    if insideZones[zone.id] then r, g, b = 0, 200, 80 end
    local cx, cy, cz = zone.pos.x, zone.pos.y, zone.pos.z
    local rad = zone.radius
    for _, tri in ipairs(_sphereMesh) do
        DrawPoly(
            cx + tri[1] * rad, cy + tri[2] * rad, cz + tri[3] * rad,
            cx + tri[4] * rad, cy + tri[5] * rad, cz + tri[6] * rad,
            cx + tri[7] * rad, cy + tri[8] * rad, cz + tri[9] * rad,
            r, g, b, a
        )
    end
end

--- A polygon's walls and edges, in any colour. Zones and ZonePreview both draw through this.
local function drawPolyShape(pts, globalMinZ, globalMaxZ, r, g, b, a, er, eg, eb)
    if not pts or #pts < 2 then return end
    for i = 1, #pts do
        local j = (i % #pts) + 1
        local x1 = pts[i].x or pts[i][1]
        local y1 = pts[i].y or pts[i][2]
        local min1 = pts[i].minZ or globalMinZ
        local max1 = pts[i].maxZ or globalMaxZ
        local x2 = pts[j].x or pts[j][1]
        local y2 = pts[j].y or pts[j][2]
        local min2 = pts[j].minZ or globalMinZ
        local max2 = pts[j].maxZ or globalMaxZ
        drawWallVarZ(x1, y1, min1, max1, x2, y2, min2, max2, r, g, b, a)
        DrawLine(x1, y1, min1, x2, y2, min2, er, eg, eb, 200)
        DrawLine(x1, y1, max1, x2, y2, max2, er, eg, eb, 200)
        DrawLine(x1, y1, min1, x1, y1, max1, er, eg, eb, 150)
    end
end

local function drawPolyZone(zone)
    local r, g, b, a = 0, 100, 255, 50
    if insideZones[zone.id] then r, g, b = 0, 200, 80 end
    local globalMinZ = zone.minZ or zone.pos.z - 2
    local globalMaxZ = zone.maxZ or zone.pos.z + 2
    drawPolyShape(zone.points, globalMinZ, globalMaxZ, r, g, b, a, r, g + 100, b)
end

-- ============================================
-- ZonePreview — draw shapes that are not zones
-- ============================================
--
-- The zone renderer, without the zone: a property's space, a unit someone is drawing, the rooms of an
-- interior are SEEN the way a zone is but are not zones (a registered zone is reported to the server,
-- which caps a player at 500). Shapes under keys, drawn with the zone look, coloured by role.
--
--   ZonePreview.set(key, shapes, style)   show these shapes under this key, replacing its last set
--   ZonePreview.clear(key)                stop showing them
--   ZonePreview.clearPrefix(prefix)       stop showing every key that starts with this
--
-- shapes  a list of WORLD shapes in the zone conventions (shared/shapes.lua): box { pos, size,
--         heading } or poly { points, minZ, maxZ }. A box's `center` is taken for `pos`, so a
--         unit's resolved shapes go straight in.
-- style   a name, or a table:
--           name    'current' (blue, the thing being worked on), 'other' (grey, its neighbours),
--                   'draft' (yellow, being drawn now), 'ok', 'warn', 'error'
--           label   text drawn above the first shape, when the camera is within 40 m
--           ms      clear itself after this long (a "here is what I just did" flash)
--
-- Client-only and local to whip_core. Nothing here reaches the server or the zone registry.

ZonePreview = {}

local PREVIEW_STYLES = {
    current = { 0, 100, 255, 50 },
    other   = { 150, 150, 160, 28 },
    draft   = { 250, 204, 21, 55 },
    ok      = { 74, 222, 128, 45 },
    warn    = { 251, 191, 36, 50 },
    error   = { 248, 113, 113, 55 },
}

--- Draw nothing further than this from the camera. Dev tools only, but a tower's worth of units
--- is thousands of polygons a frame, and one floor at a time is what anyone is looking at.
local PREVIEW_DRAW_RANGE = 150.0
local PREVIEW_LABEL_RANGE = 40.0

local _previews = {}   -- [key] = { shapes = {prepared}, rgba = {r,g,b,a}, label, untilAt }

--- Forward-declared: written below the draw loop it starts, and called from set above that.
local ensurePreviewThread

--- Show these shapes under this key, replacing whatever the key showed before.
---@param key string
---@param shapes table[]  world boxes and polys
---@param style string|table|nil
---@return boolean ok, string|nil err
function ZonePreview.set(key, shapes, style)
    if type(key) ~= 'string' or key == '' then return false, 'a preview needs a key' end
    if type(style) == 'string' then style = { name = style } end
    style = style or {}

    local prepared = {}
    for _, s in ipairs(shapes or {}) do
        local shape = s
        if s.type == 'box' and not s.pos and s.center then
            shape = { type = 'box', pos = s.center, size = s.size, heading = s.heading }
        end
        local p = Shapes.prepare(shape)
        if p then prepared[#prepared + 1] = p end
    end
    if #prepared == 0 then
        _previews[key] = nil
        return false, 'nothing to show'
    end

    local rgba = style.rgba or PREVIEW_STYLES[style.name or 'current'] or PREVIEW_STYLES.current
    _previews[key] = {
        shapes  = prepared,
        rgba    = rgba,
        label   = style.label,
        untilAt = tonumber(style.ms) and (GetGameTimer() + tonumber(style.ms)) or nil,
    }
    ensurePreviewThread()
    return true
end

function ZonePreview.clear(key)
    _previews[key] = nil
end

function ZonePreview.clearPrefix(prefix)
    for key in pairs(_previews) do
        if key:sub(1, #prefix) == prefix then _previews[key] = nil end
    end
end

--- Is anything showing under this key?
function ZonePreview.has(key)
    return _previews[key] ~= nil
end

local function drawPreviewLabel(text, x, y, z)
    SetDrawOrigin(x, y, z, 0)
    SetTextScale(0.0, 0.32)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 230)
    SetTextOutline()
    SetTextCentre(true)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(0.0, 0.0)
    ClearDrawOrigin()
end

--- One frame of every preview. Answers whether anything is still showing.
local function drawPreviews()
    if next(_previews) == nil then return false end
    local now = GetGameTimer()
    local cam = GetFinalRenderedCamCoord()
    local rangeSq = PREVIEW_DRAW_RANGE * PREVIEW_DRAW_RANGE
    local labelSq = PREVIEW_LABEL_RANGE * PREVIEW_LABEL_RANGE

    for key, p in pairs(_previews) do
        if p.untilAt and now >= p.untilAt then
            _previews[key] = nil
        else
            local r, g, b, a = p.rgba[1], p.rgba[2], p.rgba[3], p.rgba[4]
            local er, eg, eb = math.min(255, r + 60), math.min(255, g + 60), math.min(255, b + 60)
            for i, s in ipairs(p.shapes) do
                local bb = s._bbox
                local cx, cy, cz = (bb.minX + bb.maxX) * 0.5, (bb.minY + bb.maxY) * 0.5, (bb.minZ + bb.maxZ) * 0.5
                local dx, dy, dz = cx - cam.x, cy - cam.y, cz - cam.z
                local dSq = dx * dx + dy * dy + dz * dz
                if dSq <= rangeSq then
                    if s.type == 'box' then
                        drawBoxShape(s.pos, s.size, s.heading, r, g, b, a, er, eg, eb)
                    else
                        drawPolyShape(s.points, s.minZ, s.maxZ, r, g, b, a, er, eg, eb)
                    end
                    if i == 1 and p.label and dSq <= labelSq then
                        drawPreviewLabel(p.label, cx, cy, bb.maxZ + 0.2)
                    end
                end
            end
        end
    end
    return next(_previews) ~= nil
end

--- The preview thread runs only while something is showing, and is started by the set that
--- first needs it, so a preview appears on the next frame and nobody pays for an idle loop.
local _previewThread = false

function ensurePreviewThread()
    if _previewThread then return end
    _previewThread = true
    CreateThread(function()
        while drawPreviews() do Wait(0) end
        _previewThread = false
    end)
end

-- ZoneEditorActive — is the zone editor up? — is set only by the editor itself (tools/zones.lua);
-- this file reads it, and without the tool file it is simply unset, which reads as "no".

-- ============================================
-- Debug Minimap Blips
-- ============================================

local _debugBlips = {}  -- [zoneId] = { blipHandle, blipHandle, ... }

local function createDebugBlips(zone)
    if _debugBlips[zone.id] then return end
    local blips = {}

    if zone.type == 'sphere' then
        local b = AddBlipForRadius(zone.pos.x, zone.pos.y, zone.pos.z, zone.radius)
        SetBlipColour(b, 3)
        SetBlipAlpha(b, 30)
        blips[#blips + 1] = b
        local c = AddBlipForCoord(zone.pos.x, zone.pos.y, zone.pos.z)
        SetBlipSprite(c, 9)
        SetBlipScale(c, 0.03)
        SetBlipColour(c, 3)
        SetBlipDisplay(c, 8)
        blips[#blips + 1] = c

    elseif zone.type == 'box' then
        local p = zone.pos
        local s = zone.size
        local h = zone.heading or 0
        local rad = math.rad(h)
        local cosH, sinH = math.cos(rad), math.sin(rad)
        local halfX, halfY = s.x / 2, s.y / 2
        for _, off in ipairs({{-halfX,-halfY},{halfX,-halfY},{halfX,halfY},{-halfX,halfY}}) do
            local rx = off[1] * cosH - off[2] * sinH + p.x
            local ry = off[1] * sinH + off[2] * cosH + p.y
            local b = AddBlipForCoord(rx, ry, p.z)
            SetBlipSprite(b, 9)
            SetBlipScale(b, 0.02)
            SetBlipColour(b, 3)
            SetBlipDisplay(b, 8)
            blips[#blips + 1] = b
        end

    elseif zone.type == 'poly' then
        local pts = zone.points
        if pts then
            for _, pt in ipairs(pts) do
                local px = pt.x or pt[1]
                local py = pt.y or pt[2]
                local b = AddBlipForCoord(px, py, zone.pos.z)
                SetBlipSprite(b, 9)
                SetBlipScale(b, 0.02)
                SetBlipColour(b, 3)
                SetBlipDisplay(b, 8)
                blips[#blips + 1] = b
            end
        end
    end

    _debugBlips[zone.id] = blips
end

removeDebugBlips = function(zoneId)
    local blips = _debugBlips[zoneId]
    if not blips then return end
    for _, b in ipairs(blips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    _debugBlips[zoneId] = nil
end

local function updateDebugBlipColours()
    for id, blips in pairs(_debugBlips) do
        local colour = insideZones[id] and 2 or 3  -- 2 = green, 3 = blue
        for _, b in ipairs(blips) do
            if DoesBlipExist(b) then SetBlipColour(b, colour) end
        end
    end
end

local function syncDebugBlips()
    for id, zone in pairs(zones) do
        if zone.debug and not _debugBlips[id] then
            createDebugBlips(zone)
        elseif not zone.debug and _debugBlips[id] then
            removeDebugBlips(id)
        end
    end
    for id in pairs(_debugBlips) do
        if not zones[id] then removeDebugBlips(id) end
    end
    updateDebugBlipColours()
end

-- Character name cache (serverId → charName)
local _charNameCache = {}
local _charNameRetryAt = {}   -- [serverId] = when to ask again (one with no character is not asked every pass)

local function getCharDisplayName(playerId)
    local playerName = GetPlayerName(playerId) or ('Player ' .. playerId)
    local serverId = GetPlayerServerId(playerId)
    local charName = _charNameCache[serverId]
    if charName then
        return playerName .. ' (' .. charName .. ')'
    end
    return playerName .. ' [#' .. serverId .. ']'
end

-- Refresh character name cache from server (async, runs on slow tick)
--
-- Only with developer mode on (getCharName is behind whip.devtools): zone.debug is a broadcast flag, and
-- every other client would fire an ACE-denied getCharName per player every half second. Everyone else gets
-- the "[#id]" overlay labels. Reads the client's own copy of developer mode (DevToolsOn, tools/core.lua).
local function refreshCharNameCache()
    if not (DevToolsOn and DevToolsOn()) then return end

    -- Asked again, not kept for good (a player can load another character; a newcomer can get a leaver's server
    -- id): each name every 30 s (shown meanwhile), a refusal clears it, and a server id gone is forgotten.
    local activePlayers = GetActivePlayers()
    local present = {}
    for _, playerId in ipairs(activePlayers) do
        local serverId = GetPlayerServerId(playerId)
        if serverId and serverId > 0 then present[serverId] = true end
        if serverId and serverId > 0 and GetGameTimer() >= (_charNameRetryAt[serverId] or 0) then
            -- Fetch from server via callback (non-blocking, result arrives later). A refusal (no character
            -- loaded) is asked again in a while, not every pass.
            _charNameRetryAt[serverId] = GetGameTimer() + 10000
            CreateThread(function()
                local result = Callback('whip_core:getCharName', serverId)
                if type(result) == 'string' then
                    _charNameCache[serverId] = result
                    _charNameRetryAt[serverId] = GetGameTimer() + 30000
                else
                    _charNameCache[serverId] = nil
                end
            end)
        end
    end
    for serverId in pairs(_charNameRetryAt) do
        if not present[serverId] then _charNameRetryAt[serverId], _charNameCache[serverId] = nil, nil end
    end
end

-- Slow-tick data for debug overlay (updated every 500ms, not every frame)
local _debugOverlayData = {}  -- [zoneId] = { players = {}, vehicles = {} }
local _debugOverlayTick = 0

local function updateDebugOverlayData()
    _debugOverlayData = {}

    -- Fetched once per tick, not per debug zone.
    local activePlayers = GetActivePlayers()
    local vehicles = GetGamePool('CVehicle')

    for id, zone in pairs(zones) do
        if not zone.debug then goto nextZone end

        local data = { players = {}, vehicles = {} }

        -- Check all players
        for _, playerId in ipairs(activePlayers) do
            local ped = GetPlayerPed(playerId)
            if ped and ped > 0 and DoesEntityExist(ped) then
                local pos = GetEntityCoords(ped)
                if isPointInZone(zone, pos.x, pos.y, pos.z) then
                    data.players[#data.players + 1] = getCharDisplayName(playerId)
                end
            end
        end

        -- Check nearby vehicles (pool hoisted above the loop)
        for _, veh in ipairs(vehicles) do
            if DoesEntityExist(veh) then
                local vPos = GetEntityCoords(veh)
                if isPointInZone(zone, vPos.x, vPos.y, vPos.z) then
                    local plate = GetVehicleNumberPlateText(veh) or '???'
                    local model = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
                    data.vehicles[#data.vehicles + 1] = (model or '?') .. ' [' .. plate .. ']'
                end
            end
        end

        _debugOverlayData[id] = data
        ::nextZone::
    end
end

local function drawDebugOverlayText()
    local myPed = PlayerPedId()
    local myPos = GetEntityCoords(myPed)
    local headPos = myPos + vector3(0, 0, 1.1)

    -- Collect info about zones the player is in
    local lines = {}
    local inAny = false

    for id in pairs(insideZones) do
        local zone = zones[id]
        if zone and zone.debug then
            inAny = true
            lines[#lines + 1] = '~b~Zone:~w~ ' .. (zone.label or zone.id)

            local data = _debugOverlayData[id]
            if data then
                if #data.players > 0 then
                    lines[#lines + 1] = '~y~Players:~w~ ' .. table.concat(data.players, ', ')
                else
                    lines[#lines + 1] = '~y~Players:~w~ None'
                end
                if #data.vehicles > 0 then
                    lines[#lines + 1] = '~o~Vehicles:~w~ ' .. table.concat(data.vehicles, ', ')
                else
                    lines[#lines + 1] = '~o~Vehicles:~w~ None'
                end
            end
            lines[#lines + 1] = '' -- spacer between zones
        end
    end

    if not inAny then
        -- Check if any debug zone exists — show "not in any zone"
        local hasDebug = false
        for _, zone in pairs(zones) do
            if zone.debug then hasDebug = true; break end
        end
        if hasDebug then
            lines[#lines + 1] = '~r~Not in any zone'
        end
    end

    if #lines == 0 then return end

    -- Draw above player head
    SetDrawOrigin(headPos.x, headPos.y, headPos.z, 0)
    for i, line in ipairs(lines) do
        SetTextScale(0.0, 0.30)
        SetTextFont(4)
        SetTextProportional(true)
        SetTextColour(255, 255, 255, 220)
        SetTextOutline()
        SetTextCentre(true)
        SetTextEntry('STRING')
        AddTextComponentString(line)
        DrawText(0.0, -0.02 * (#lines - i + 1))
    end
    ClearDrawOrigin()
end

--- The debug drawing, running only while a zone has debug on: started when a zone is registered with
--- debug or has it switched on; it ends, clearing the blips, when none is left.
local debugDrawRunning = false

local function debugDraw()
    while true do
        local hasDebug = false
        for _, zone in pairs(zones) do
            if zone.debug then
                hasDebug = true
                if zone.type == 'box' then drawBoxZone(zone)
                elseif zone.type == 'sphere' then drawSphereZone(zone)
                elseif zone.type == 'poly' then drawPolyZone(zone) end
            end
        end

        -- Debug overlay text + minimap blips (only when NOT in editor)
        if hasDebug and not ZoneEditorActive then
            _debugOverlayTick = _debugOverlayTick + 1
            if _debugOverlayTick >= 30 then
                _debugOverlayTick = 0
                updateDebugOverlayData()
                syncDebugBlips()
                refreshCharNameCache()
            end
            drawDebugOverlayText()
        elseif not hasDebug then
            -- Clean up all blips when no debug zones
            for id in pairs(_debugBlips) do removeDebugBlips(id) end
        end

        if not hasDebug then break end
        Wait(0)
    end
    debugDrawRunning = false
end

startDebugDraw = function()
    if debugDrawRunning then return end
    debugDrawRunning = true
    CreateThread(debugDraw)
end

-- ============================================
-- Auto-Cleanup on Resource Stop
-- ============================================

AddEventHandler('onResourceStop', function(resName)
    -- whip_core itself: its zones go with it, so every car one capped is put back now.
    if resName == GetCurrentResourceName() then uncapAll() return end
    local toRemove = {}
    for id, zone in pairs(zones) do
        if zone._owner == resName then toRemove[#toRemove + 1] = id end
    end
    for _, id in ipairs(toRemove) do
        removeZone(id)
    end
end)

-- ============================================
-- Exports
-- ============================================

local ZONE_TYPES = { box = true, sphere = true, poly = true }

-- A zone is one table with its `type`; anything else is refused with its shape, rather than an error deep in
-- whip_core. Returns the zone's id.
exports('RegisterZone', function(data)
    local owner = GetInvokingResource()   -- first, before anything can yield
    if type(data) ~= 'table' or not ZONE_TYPES[data.type] then
        return false, "RegisterZone needs { type = 'box', pos, size }, { type = 'sphere', pos, radius } or { type = 'poly', points }"
    end
    data._owner = owner
    return registerZone(data.type, data)
end)

-- The caller is passed so a resource can only remove its own. Zones.remove (below) is whip_core's.
exports('RemoveZone', function(id) return removeOwnZone(id, Registry.caller()) end)
exports('RemoveZoneGroup', function(group) return removeGroup(group, Registry.caller()) end)

--- The zone a setter may change: found by its id or, for a saved zone, its key, and only the
--- caller's own. whip_core itself may change any zone (its editor).
---@return table|nil zone
---@return string|nil id
---@return string|nil why
local function ownZone(idOrKey, caller)
    local id = zoneIdOf(idOrKey)
    -- The caller's OWN zone by that exact id is the one its setters mean, even where a saved zone's key
    -- takes the name in lookups (zoneIdOf).
    local mine = zones[idOrKey]
    if mine and caller ~= CORE and (mine._owner or CORE) == caller then id = idOrKey end
    local zone = id and zones[id]
    if not zone then return nil, nil, ('no zone "%s"'):format(tostring(idOrKey)) end
    if caller ~= CORE and (zone._owner or CORE) ~= caller then
        return nil, nil, ('zone "%s" belongs to %s'):format(tostring(idOrKey), zone._owner or CORE)
    end
    return zone, id
end

--- whip_core's own zone calls: the editor (tools/zones.lua) changes zones as whip_core
--- through these — `Zones.update(id, { debug = on })`, `Zones.remove(id)` — never through its own exports.
Zones = {}

--- What each UpdateZone key does to the zone, `fn(zone, id, value)`: nothing returned, or `false, why`.
local PATCH = {
    pos = function(_, id, pos) updatePosition(id, pos) end,
    size = function(_, id, size) return updateSize(id, size) end,
    -- false takes the condition off (a nil in a table is no key at all)
    condition = function(zone, _, fn) zone.condition = fn or nil end,
    debug = function(zone, _, enabled)
        zone.debug = enabled == true
        if enabled then startDebugDraw() end
    end,
    trackVehicles = function(zone, _, enabled) zone.trackVehicles = enabled == true end,
    label = function(zone, _, label) zone.label = label end,
    priority = function(zone, _, priority) zone.priority = priority end,
    notify = function(zone, _, enabled) zone.notify = enabled == true end,
    rules = function(zone, id, rules)
        -- The old rules' effects come off first; the enforcement loop applies the new ones. false: no rules.
        if insideZones[id] then revertZoneRules(zone, insideZones) end
        zone.rules = rules or nil
    end,
}
--- In this order: where the zone is first, then its size.
local PATCH_ORDER = { 'pos', 'size', 'condition', 'debug', 'trackVehicles', 'label', 'priority', 'notify', 'rules' }

--- A point: a vector3 or vector4, or a table with numeric x and y (and z when `needZ`).
local function isPoint(v, needZ)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    return t == 'table' and type(v.x) == 'number' and type(v.y) == 'number' and (not needZ or type(v.z) == 'number')
end

--- Why `patch` cannot apply to `zone`, or nil. The checks a value fails only once it is half applied are made here
--- first: a bad pos used to take the zone off its cells and then throw, leaving it on none.
local function patchRefusal(zone, patch)
    if patch.pos ~= nil and not isPoint(patch.pos) then return 'UpdateZone: pos is a vector3' end
    local size = patch.size
    if size ~= nil then
        if zone.type == 'poly' then return 'a poly zone is resized by editing its points' end
        if zone.type == 'box' and not isPoint(size, true) then return "UpdateZone: a box zone's size is a vector3" end
        if zone.type == 'sphere' and type(size) ~= 'number' and not isPoint(size) then
            return "UpdateZone: a sphere zone's size is its radius (a number)"
        end
    end
    return nil
end

--- Change a zone of `caller`'s: each key of `patch` (PATCH above), checked before any is applied, so a bad key
--- changes nothing. Returns `true`, or `false, why`.
---@param caller string
---@param idOrKey string
---@param patch table
---@return boolean ok
---@return string|nil why
local function updateZone(caller, idOrKey, patch)
    if type(patch) ~= 'table' then
        return false, 'UpdateZone(id, patch): patch is a table of pos, size, condition, debug, trackVehicles, label, priority, notify, rules'
    end
    for k in pairs(patch) do
        if not PATCH[k] then return false, ('UpdateZone: no key "%s" (pos, size, condition, debug, trackVehicles, label, priority, notify, rules)'):format(tostring(k)) end
    end
    local zone, id, why = ownZone(idOrKey, caller)
    if not zone then return false, why end
    local refused = patchRefusal(zone, patch)
    if refused then return false, refused end
    for _, k in ipairs(PATCH_ORDER) do
        local v = patch[k]
        if v ~= nil then
            -- Guarded, and its refusal passed on: an update must not throw into the calling resource.
            local okCall, ok, err = pcall(PATCH[k], zone, id, v)
            if not okCall then return false, tostring(ok) end
            if ok == false then return false, err end
        end
    end
    return true
end

-- The export reads its caller first (before anything can yield); Zones.update is whip_core's.
exports('UpdateZone', function(idOrKey, patch) return updateZone(Registry.caller(), idOrKey, patch) end)
function Zones.update(idOrKey, patch) return updateZone(CORE, idOrKey, patch) end

---@diagnostic disable-next-line: duplicate-set-field -- the server's Zones is a different table
function Zones.remove(id) return removeOwnZone(id, CORE) end

exports('IsPointInZone', function(id, point) return checkContains(id, point) end)

exports('IsInZone', function(id)
    return insideZones[zoneIdOf(id)] == true
end)

--- The same question for whip_core's own files (client/actions.lua's `require = { zone = ... }`),
--- without a round trip through the export machinery. A saved zone may be named by its key.
---@param id string
---@return boolean
function IsInsideZone(id)
    return insideZones[zoneIdOf(id)] == true
end

exports('GetZonesInside', function()
    local result = {}
    for id in pairs(insideZones) do result[#result + 1] = id end
    return result
end)

--- Get a specific zone's data by ID (client-side).
exports('GetZone', function(id)
    local zone = zones[zoneIdOf(id)]
    if not zone then return nil end
    return {
        id       = zone.id,
        type     = zone.type,
        pos      = zone.pos,
        size     = zone.size,
        radius   = zone.radius,
        heading  = zone.heading,
        points   = zone.points,
        minZ     = zone.minZ,
        maxZ     = zone.maxZ,
        group    = zone.group,
        label    = zone.label,
        priority = zone.priority,
        rules    = zone.rules,
        notify   = zone.notify,
        debug    = zone.debug or false,
        inside   = insideZones[zone.id] == true,
        -- WHETHER a condition is attached (it gates the enter/exit events), not the function
        -- itself: the predicate belongs to whoever set it, and runs only in the poll.
        hasCondition = zone.condition ~= nil,
    }
end)

--- Get all zones near a point within a radius.
exports('GetZonesNearby', function(pos, radius)
    radius = radius or 50.0
    local result = {}
    local radiusSq = radius * radius
    for _, zone in pairs(zones) do
        local dx = zone.pos.x - pos.x
        local dy = zone.pos.y - pos.y
        if (dx * dx + dy * dy) <= radiusSq then
            result[#result + 1] = {
                id    = zone.id,
                type  = zone.type,
                label = zone.label,
                pos   = zone.pos,
                dist  = math.sqrt(dx * dx + dy * dy),
            }
        end
    end
    table.sort(result, function(a, b) return a.dist < b.dist end)
    return result
end)

-- ============================================
-- Persistent Zone Sync (from DB via server)
-- ============================================

--- Register one persistent zone from the server's description of it.
---
--- One place for both handlers below, carrying rules, notify and trackVehicles.
local function registerDbZone(data)
    if data.key then dbZoneByKey[data.key] = data.id end
    -- The outline survives a re-registration (every edit of a saved zone arrives as one): debug is
    -- kept as it was, and on for anything new while the editor is up.
    local held = zones[data.id]
    local debug = (held and held.debug) or (ZoneEditorActive == true) or nil
    registerZone(data.type, {
        debug         = debug,
        id            = data.id,
        pos           = data.pos,
        size          = data.size,
        heading       = data.heading,
        radius        = data.radius,
        points        = data.points,
        minZ          = data.minZ,
        maxZ          = data.maxZ,
        group         = data.group,
        label         = data.label,
        priority      = data.priority,
        rules         = data.rules,
        notify        = data.notify,
        trackVehicles = data.trackVehicles,
        _owner        = 'whip_core',
        _dbZone       = true,
    })
end

-- Receive all persistent zones on connect
RegisterNetEvent('whip_core:client:zonesSync', function(dbZoneList)
    if not dbZoneList then return end
    for _, data in ipairs(dbZoneList) do
        if not zones[data.id] then registerDbZone(data) end
    end
end)

-- Single persistent zone created (broadcast)
RegisterNetEvent('whip_core:client:zoneDbCreated', function(data)
    if not data or zones[data.id] then return end
    registerDbZone(data)
end)

-- Persistent zone updated
RegisterNetEvent('whip_core:client:zoneDbUpdated', function(id, data)
    if not zones[id] or type(data) ~= 'table' then return end

    -- A WHOLE saved zone (the server's zoneWire, marked dbZone) replaces the old one outright:
    -- re-registering an id is a clean swap. A field-by-field merge could not take a field AWAY (a nil
    -- is no key at all). Partial updates still merge below.
    if data.dbZone == true and data.id == id and data.type then
        registerDbZone(data)
        return
    end
    if data.pos then updatePosition(id, data.pos) end
    if data.size then updateSize(id, data.size) end
    if data.label ~= nil then zones[id].label = data.label end
    if data.group ~= nil then zones[id].group = data.group end
    if data.priority ~= nil then zones[id].priority = data.priority end
    if data.rules ~= nil then
        -- The old rules' effects come off first; the enforcement loop applies the new ones.
        if insideZones[id] then revertZoneRules(zones[id], insideZones) end
        zones[id].rules = data.rules
    end
    if data.trackVehicles ~= nil then zones[id].trackVehicles = data.trackVehicles end
    if data.notify ~= nil then zones[id].notify = data.notify end
    if data.heading then
        zones[id].heading = data.heading
        local rad = math.rad(data.heading)
        zones[id]._cosH = math.cos(rad)
        zones[id]._sinH = math.sin(rad)
    end
    if data.points then
        zones[id].points = data.points
        local minX, maxX = math.huge, -math.huge
        local minY, maxY = math.huge, -math.huge
        local sumX, sumY = 0, 0
        for _, p in ipairs(data.points) do
            local px = p.x or p[1]
            local py = p.y or p[2]
            if px < minX then minX = px end
            if px > maxX then maxX = px end
            if py < minY then minY = py end
            if py > maxY then maxY = py end
            sumX = sumX + px
            sumY = sumY + py
        end
        zones[id]._bbox = { minX = minX, maxX = maxX, minY = minY, maxY = maxY }
        if #data.points > 0 then
            zones[id].pos = vector3(sumX / #data.points, sumY / #data.points, zones[id].pos and zones[id].pos.z or 0)
        end
        unregisterZoneCells(id)
        registerZoneCells(zones[id])
    end
    if data.minZ ~= nil then zones[id].minZ = data.minZ end
    if data.maxZ ~= nil then zones[id].maxZ = data.maxZ end
    -- Names taken off a script's zone (a nil cannot travel, so the server lists them).
    if type(data.clear) == 'table' then
        for _, k in ipairs(data.clear) do
            if k == 'group' or k == 'label' then zones[id][k] = nil end
        end
    end
    -- New points or new heights: the containment bounds follow (computePolyZ).
    if zones[id].type == 'poly' and (data.points or data.minZ ~= nil or data.maxZ ~= nil) then
        computePolyZ(zones[id])
    end
end)

-- Persistent zone deleted
RegisterNetEvent('whip_core:client:zoneDbDeleted', function(id)
    for key, zid in pairs(dbZoneByKey) do
        if zid == id then dbZoneByKey[key] = nil end
    end
    removeZone(id)
end)

-- ============================================
-- Internal: get all zones for dev tool
-- ============================================

function GetAllZonesForTool()
    local result = {}
    for _, zone in pairs(zones) do
        result[#result + 1] = {
            id       = zone.id,
            type     = zone.type,
            pos      = zone.pos,
            size     = zone.size,
            radius   = zone.radius,
            heading  = zone.heading,
            points   = zone.points,
            minZ     = zone.minZ,
            maxZ     = zone.maxZ,
            group    = zone.group,
            label    = zone.label,
            debug    = zone.debug,
            priority = zone.priority,
            inside   = insideZones[zone.id] == true,
            trackVehicles = zone.trackVehicles,
            rules    = zone.rules,
            notify   = zone.notify,
            _owner   = zone._owner,
            _dbZone  = zone._dbZone,
        }
    end
    return result
end
