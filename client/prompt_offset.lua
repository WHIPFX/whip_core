PromptOffset = {}

local defaults = {}
local byName = {}
local hasVisual = false

function PromptOffset.radius(value)
    return type(value) == 'number' and value >= 0.01 and value <= 5.0
end

function PromptOffset.xyz(value)
    local kind = type(value)
    if kind ~= 'vector3' and kind ~= 'vector4' and kind ~= 'table' then return nil end
    if kind == 'table' and rawget(value, '__cfx_functionReference') ~= nil then return nil end
    local x, y, z = tonumber(value.x or value[1]), tonumber(value.y or value[2]), tonumber(value.z or value[3])
    if not x or not y or not z or x ~= x or y ~= y or z ~= z
        or math.abs(x) == math.huge or math.abs(y) == math.huge or math.abs(z) == math.huge then return nil end
    return x, y, z
end

for model, placement in pairs(Config.PropPromptDefaultOffset or {}) do
    local hash = type(model) == 'string' and GetHashKey(model) or (type(model) == 'number' and math.tointeger(model))
    local x, y, z
    if type(placement) == 'table' then x, y, z = PromptOffset.xyz(placement.offset) end
    local heading
    if type(placement) == 'table' then heading = placement.heading end
    if hash and x and (heading == nil or heading == false or (type(heading) == 'number' and heading == heading and math.abs(heading) < math.huge))
        and (placement.visualOffset == nil or PromptOffset.xyz(placement.visualOffset))
        and (placement.radius == nil or PromptOffset.radius(placement.radius)) then
        local radius = placement.radius
        hasVisual = hasVisual or placement.visualOffset ~= nil
        defaults[hash & 0xFFFFFFFF] = { offset = vector3(x, y, z), heading = heading,
            visualOffset = placement.visualOffset, radius = radius,
            prop = { side = x, out = y, up = z, yaw = heading, visualOffset = placement.visualOffset, radius = radius } }
    else
        print(('[whip_core:interact] Invalid PropPromptDefaultOffset for %s'):format(tostring(model)))
    end
end

local hasDefaults = next(defaults) ~= nil

function PromptOffset.get(model)
    if not hasDefaults then return nil end
    if type(model) ~= 'string' then return defaults[model & 0xFFFFFFFF] end
    if byName[model] == nil then byName[model] = defaults[GetHashKey(model) & 0xFFFFFFFF] or false end
    return byName[model] or nil
end

function PromptOffset.resolve(model, offset, heading, visualOffset, radius)
    if heading ~= false then heading = tonumber(heading) end
    if offset ~= nil and not PromptOffset.xyz(offset) then offset = nil end
    if visualOffset ~= nil and not PromptOffset.xyz(visualOffset) then visualOffset = nil end
    local default = PromptOffset.get(model)
    if default then
        if offset == nil then offset = default.offset end
        if heading == nil then heading = default.heading end
        if visualOffset == nil then visualOffset = default.visualOffset end
        if radius == nil then radius = default.radius end
    end
    return offset, heading, visualOffset, radius
end

function PromptOffset.follow(offset, heading, radius)
    local x, y, z = PromptOffset.xyz(offset)
    if not hasDefaults and not x and heading == nil and radius == nil then return nil end
    local turn = heading
    if turn ~= false then turn = tonumber(turn) end
    local needsDefault = hasDefaults and (not x or heading == nil or radius == nil)
    local reach = radius
    local last
    local function resolve(entity)
        if needsDefault and entity ~= last then
            last = entity
            if entity then
                local resolved, visual
                resolved, turn, visual, reach = PromptOffset.resolve(GetEntityModel(entity), offset, heading, nil, radius)
                x, y, z = PromptOffset.xyz(resolved)
            end
        end
        return x, y, z, turn, reach
    end
    return resolve, function() return reach end
end

function PromptOffset.visual(entityNow, offset)
    local ox, oy, oz = PromptOffset.xyz(offset)
    if not ox and not hasVisual then return nil end
    if ox == 0.0 and oy == 0.0 and oz == 0.0 then return nil end
    local last, x, y, z
    return function(px, py, pz)
        local entity = entityNow()
        if not entity or not DoesEntityExist(entity) then return nil end
        if last ~= entity then
            last = entity
            x, y, z = ox, oy, oz
            if not x then
                local default = PromptOffset.get(GetEntityModel(entity))
                x, y, z = PromptOffset.xyz(default and default.visualOffset)
            end
        end
        if not x or (x == 0.0 and y == 0.0 and z == 0.0) then return nil end
        local origin = GetEntityCoords(entity)
        local p = GetOffsetFromEntityInWorldCoords(entity, x, y, z)
        return px + p.x - origin.x, py + p.y - origin.y, pz + p.z - origin.z
    end
end

local view = {}

local function sightView(fresh)
    local frame = GetFrameCount()
    if fresh or view.frame ~= frame then
        view.frame, view.ped = frame, PlayerPedId()
        view.player = GetEntityCoords(view.ped)
        view.camera = GetFinalRenderedCamCoord()
        view.fx, view.fy, view.fz = InteractGetCameraForward()
        view.head = nil
    end
    return view
end

local function clearTo(from, x, y, z, ped)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, x, y, z, 1 | 2 | 4 | 8 | 16 | 64, ped, 4)
    local status, hit, at = GetShapeTestResult(ray)
    if status ~= 2 then return false end
    if not (hit == 1 or hit == true) then return true end
    local ex, ey, ez = at.x - x, at.y - y, at.z - z
    return ex * ex + ey * ey + ez * ez <= 0.03 * 0.03
end

function PromptOffset.check(x, y, z, radius, reach, cache, fresh)
    local v = sightView(fresh)
    local p = v.player
    local dx, dy, dz = x - p.x, y - p.y, z - p.z
    if dx * dx + dy * dy + dz * dz > reach * reach then return false end
    local cam = v.camera
    dx, dy, dz = x - cam.x, y - cam.y, z - cam.z
    local along = dx * v.fx + dy * v.fy + dz * v.fz
    local length = dx * dx + dy * dy + dz * dz
    if along <= 0 or length - along * along > radius * radius then return false end
    local now = GetGameTimer()
    if fresh or not cache.at or now - cache.at >= 100 then
        v.head = v.head or GetPedBoneCoords(v.ped, 31086, 0.0, 0.0, 0.0)
        cache.at = now
        cache.clear = clearTo(cam, x, y, z, v.ped) and clearTo(v.head, x, y, z, v.ped)
    end
    return cache.clear, along * along / math.max(length, 0.000001)
end

function PromptOffset.target(where, reach, visibleRange)
    local cache = {}
    return function(fresh)
        local x, y, z, radius = where(fresh)
        if not x then return false end
        if not radius then return true end
        local ok = PromptOffset.check(x, y, z, radius,
            fresh and (reach or Config.InteractActiveRange or 3.0) or (visibleRange or Config.InteractVisibleRange or 5.0), cache, fresh)
        return ok, true
    end
end

local poolNames = { object = 'CObject', vehicle = 'CVehicle', ped = 'CPed' }
local pools, closest = {}, {}

local function pool(kind, now)
    local cached = pools[kind]
    if not cached or now - cached.at >= 500 then
        cached = { at = now, entities = {} }
        pools[kind] = cached
        for _, entity in ipairs(GetGamePool(poolNames[kind])) do
            if DoesEntityExist(entity) then cached.entities[entity] = GetEntityModel(entity) & 0xFFFFFFFF end
        end
    end
    return cached.entities
end

function PromptOffset.finder(kinds, models, offset, heading, radius)
    if not (kinds.object or kinds.vehicle or kinds.ped) then return nil end
    local hashes = {}
    if models then
        for hash in pairs(models) do
            if radius ~= nil or (defaults[hash] and defaults[hash].radius) then hashes[hash] = true end
        end
        if next(hashes) == nil then return nil end
    elseif radius == nil then
        for hash, placement in pairs(defaults) do
            if placement.radius then hashes[hash] = true end
        end
        if next(hashes) == nil then return nil end
    end
    local all = not models and radius ~= nil
    local candidates, nextScan = {}, 0
    return function(out, range)
        local now = GetGameTimer()
        if now >= nextScan then
            nextScan = now + 500
            local seen, old = {}, candidates
            local player = GetEntityCoords(PlayerPedId())
            candidates = {}
            local function add(entity, model)
                if seen[entity] or (not all and not hashes[model]) then return end
                seen[entity] = true
                local c = old[entity]
                if not c or c.model ~= model then
                    local point, turn, visual, r = PromptOffset.resolve(model, offset, heading, nil, radius)
                    local x, y, z = PromptOffset.xyz(point)
                    c = { model = model, x = x or 0.0, y = y or 0.0, z = z or 0.0, heading = turn,
                          radius = r, sight = {} }
                end
                local p = GetOffsetFromEntityInWorldCoords(entity, c.x, c.y, c.z)
                local dx, dy, dz = p.x - player.x, p.y - player.y, p.z - player.z
                if dx*dx + dy*dy + dz*dz <= (range + 5.0)^2 then candidates[entity] = c end
            end
            for kind in pairs(kinds) do
                if poolNames[kind] then
                    for entity, model in pairs(pool(kind, now)) do add(entity, model) end
                end
            end
            if kinds.object then
                local p = GetEntityCoords(PlayerPedId())
                for hash in pairs(hashes) do
                    local offsetForModel = offset or (defaults[hash] and defaults[hash].offset)
                    local x, y, z = PromptOffset.xyz(offsetForModel)
                    local search = range + math.sqrt((x or 0)^2 + (y or 0)^2 + (z or 0)^2)
                    local c = closest[hash]
                    if not c or now - c.at >= 500 or c.x ~= p.x or c.y ~= p.y or c.z ~= p.z or c.range ~= search then
                        c = { at = now, x = p.x, y = p.y, z = p.z, range = search,
                              entity = GetClosestObjectOfType(p.x, p.y, p.z, search, hash, false, false, false) }
                        closest[hash] = c
                    end
                    if c.entity and c.entity ~= 0 and DoesEntityExist(c.entity) then add(c.entity, hash) end
                end
            end
        end
        local best, score = nil, -1
        local ped = PlayerPedId()
        for entity, c in pairs(candidates) do
            if entity ~= ped and DoesEntityExist(entity) then
                local p = GetOffsetFromEntityInWorldCoords(entity, c.x, c.y, c.z)
                local ok, aim = PromptOffset.check(p.x, p.y, p.z, c.radius, range, c.sight)
                if ok and aim > score then
                    best, score = entity, aim
                    out.x, out.y, out.z = p.x, p.y, p.z
                    out.heading = c.heading and (GetEntityHeading(entity) + c.heading) % 360.0 or nil
                    out.radius = c.radius
                end
            else
                candidates[entity] = nil
            end
        end
        if not best then return false end
        out.entity, out.px, out.py, out.pz = best, out.x, out.y, out.z
        out.wrap, out.nx, out.ny, out.nz = nil, nil, nil, nil
        return true
    end
end
