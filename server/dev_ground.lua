-- ============================================
-- Ground Items Debug — the server half of the /w tool
-- ============================================
--
-- Two lists, to the admins who turned it on:
--   NEAR, once a second: every ground item in the viewer's cell of the ground grid and the eight
--     around it, in full — what, how many, where, how long it has lain there, who dropped it. The
--     debug panel's figures for the area are these.
--   FAR, every FAR_EVERY seconds: the nearest FAR_MAX items within FAR_RANGE, smaller rows, for the
--     beams and map marks that let an admin flying over the map see where everything is (kilometres
--     away). Every item on the server is walked for it — the grid answers for
--     cells, and at this range that is thousands of them.
-- tools/ground_debug.lua draws both (a beam into the sky and a map mark each, the one you aim at lit).
--
-- WHO DROPPED IT is the ground row's createdBy (a charId). A name is looked up once and kept: an
-- online character's from Players, anyone else's from the characters table.
--
-- The loop is born with the first viewer and ends with the last, and each push asks again
-- (DevTools.eachViewer): developer mode off drops the viewer at the next second.

local viewers = DevTools.viewers.gd
local PUSH_MS = 1000
local looping = false

local FAR_RANGE = 4000.0   -- metres, flat
local FAR_MAX   = 1000     -- the nearest this many
local FAR_EVERY = 3        -- seconds between far lists

--- [source] = pushes so far, so each viewer's far list comes every FAR_EVERY pushes from their first.
local _pushes = {}

--- [charId] = 'First Last', or false when there is no such character. Kept for the session (the lookup is a query),
--- and forgotten when the character is renamed (the admin panel can, since 1 Nov).
local _names = {}
Character.onLife('renamed', function(e)   -- core's own hook, not the public event (character.lua Character.rename)
    if type(e) == 'table' and e.charId then _names[e.charId] = nil end
end)

--- Names for every charId in `ids` ({ [charId] = true }) that is not known yet: the online ones
--- from Players, the rest in one query.
local function learnNames(ids)
    local missing = {}
    for charId in pairs(ids) do
        if _names[charId] == nil then
            for _, p in pairs(Players) do
                if p.charId == charId then _names[charId] = p.fullName; break end
            end
            if _names[charId] == nil then missing[#missing + 1] = charId end
        end
    end
    if #missing == 0 then return end
    local marks = {}
    for i = 1, #missing do marks[i] = '?' end
    local ok, rows = pcall(MySQL.query.await,
        'SELECT `charId`, `firstName`, `lastName` FROM `characters` WHERE `charId` IN (' .. table.concat(marks, ',') .. ')',
        missing)
    if not ok then return end   -- asked again next second
    for _, id in ipairs(missing) do _names[id] = false end
    for _, row in ipairs(rows or {}) do
        _names[row.charId] = ('%s %s'):format(row.firstName or '?', row.lastName or '')
    end
end

--- The items in the 3x3 cells around `source`, as the client wants them.
local function itemsFor(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil end
    local at = GetEntityCoords(ped)
    local cellSize = Config.GroundItemCellSize or 50
    local items = GroundItems.getItemsInCells(GroundItems.getNearbyCellKeys(at.x, at.y, cellSize))
    local now = os.time()
    local list, who = {}, {}
    for id, data in pairs(items) do
        -- A pile still in the air (a throw) has no place to mark yet.
        if GroundItems.flightOwner(id) == nil then
            local def = Config.Items[data.item]
            list[#list + 1] = {
                id = id, k = data.item, l = def and def.name or data.item, a = data.amount,
                x = data.x, y = data.y, z = data.z,
                age = math.max(0, now - (tonumber(data.createdAt) or now)),
                by = data.createdBy,
            }
            if data.createdBy then who[data.createdBy] = true end
        end
    end
    learnNames(who)
    for _, it in ipairs(list) do
        if it.by then it.bn = _names[it.by] or nil end
    end
    return { cell = GroundItems.cellKey(at.x, at.y), cellSize = cellSize, items = list }
end

--- The nearest FAR_MAX items within FAR_RANGE of `source` (flat distance), nearest first, as
--- { id, k, a, x, y, z, age, by }, with the droppers' names beside them ({ [charId] = name }).
local function farFor(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil end
    local at = GetEntityCoords(ped)
    local reach = FAR_RANGE * FAR_RANGE
    local found = {}
    for id, data in pairs(GroundItems.cache) do
        local dx, dy = data.x - at.x, data.y - at.y
        local d2 = dx * dx + dy * dy
        if d2 <= reach and GroundItems.flightOwner(id) == nil then
            found[#found + 1] = { data = data, d2 = d2 }
        end
    end
    table.sort(found, function(a, b) return a.d2 < b.d2 end)
    local now = os.time()
    local list, who = {}, {}
    for i = 1, math.min(#found, FAR_MAX) do
        local data = found[i].data
        list[i] = {
            id = data.id, k = data.item, a = data.amount, x = data.x, y = data.y, z = data.z,
            age = math.max(0, now - (tonumber(data.createdAt) or now)), by = data.createdBy,
        }
        if data.createdBy then who[data.createdBy] = true end
    end
    learnNames(who)
    local names = {}
    for charId in pairs(who) do names[charId] = _names[charId] or nil end
    return { items = list, names = names, range = FAR_RANGE, total = #found }
end

local function startLoop()
    if looping then return end
    looping = true
    CreateThread(function()
        while next(viewers) do
            DevTools.eachViewer(viewers, function(src)
                local ok, data = pcall(itemsFor, src)
                if not ok then
                    print(('[whip_core:dev] Ground Items Debug could not read the items: %s'):format(tostring(data)))
                elseif data then
                    TriggerClientEvent('whip_core:client:groundDebug', src, data)
                end
                _pushes[src] = (_pushes[src] or 0) + 1
                if _pushes[src] % FAR_EVERY == 1 then
                    local fok, far = pcall(farFor, src)
                    if not fok then
                        print(('[whip_core:dev] Ground Items Debug could not read the far items: %s'):format(tostring(far)))
                    elseif far then
                        TriggerClientEvent('whip_core:client:groundDebugFar', src, far)
                    end
                end
            end)
            Wait(PUSH_MS)
        end
        looping = false
    end)
end

--- On or off. NO ACE: turning it off is never refused. Turning it on asks DevTools.isAllowed itself,
--- so an admin with developer mode off is told why.
SecureEvent('whip_core:server:groundDebug', {
    rateLimit = 500, burst = 3,   -- (an off straight after an on is never refused)
    whileDead = true,
    requirePlayer = false,
    params = { {'on', 'bool'} },
}, function(source, _, on)
    if not on then
        viewers[source] = nil
        _pushes[source] = nil
        return
    end
    if not DevTools.isAllowed(source) then
        if DevTools.isEligible(source) then
            DevTools.sayOff(source)
            return false
        end
        return false, 'Not permitted'
    end
    viewers[source] = true
    _pushes[source] = nil   -- the far list comes with the first push
    startLoop()
end)

AddEventHandler('playerDropped', function() _pushes[source] = nil end)
