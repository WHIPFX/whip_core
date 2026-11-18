-- ============================================
-- SPAWN CHOICES — server/spawn_choices.lua
-- ============================================
--
-- Where a character may arrive, for the spawn picker on the 3D map (client/charselect.lua,
-- html/js/spawn-pick.js): where they last were, the server's spawn points (Config.SpawnPoints), and every
-- property they own or hold a key to.
--
-- The list rides the character list (Character.list), so the picker can open the moment a character is
-- confirmed. The client sends back only the choice's id, and SpawnChoices.resolve reads it again here, live: a
-- spawn point removed or a key taken since the list was sent is refused, never trusted.
--
-- A choice: { id, kind = 'last'|'preset'|'property', label, x, y, z, heading }. `id` is 'last',
-- 'preset:<id>', 'property:<propertyId>' or 'res:<resource>:<id>' (RegisterSpawnPoint, below: drawn as a preset).
-- Only a name: the picker shows the name and its kind's icon (Josh).

SpawnChoices = {}

-- The longest choice id the game may send back (server/player_lifecycle.lua reads it at this length): a registered
-- point's 'res:<resource>:<id>' is the longest, and is refused at registering when it would be longer.
SpawnChoices.ID_MAX = 96

--- GTA's heading (degrees, 0 = north, counter-clockwise) for a direction on the ground.
local function headingOf(dx, dy)
    if dx == 0 and dy == 0 then return 0.0 end
    return (math.deg(math.atan(-dx, dy)) + 360.0) % 360.0
end

local function num(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

--- A spawn point from Config.SpawnPoints as a choice, or nil when the row is not usable.
local function presetChoice(p)
    if type(p) ~= 'table' or type(p.id) ~= 'string' or p.id == '' then return nil end
    local pos = p.pos
    local x, y, z = pos and num(pos.x), pos and num(pos.y), pos and num(pos.z)
    if not (x and y and z) then return nil end
    return {
        id = 'preset:' .. p.id, kind = 'preset',
        label = type(p.label) == 'string' and p.label ~= '' and p.label or p.id,
        x = x, y = y, z = z, heading = num(pos.w) or 0.0,
    }
end

-- ============================================
-- A resource's own spawn points (RegisterSpawnPoint)
-- ============================================
--
-- Beside config.lua's: a gang's hideout, a job's depot, a hotel a housing script runs. Each resource's ids are its
-- own (the registry is scoped), they go when it stops, and `canUse(charId)` can keep one to some characters. Listed
-- after the config's, and read again live when picked, like every other choice.

local MAX_REGISTERED = 30
local registered = {}   -- ['<resource>:<id>'] = { label, x, y, z, heading, canUse }
local spawnReg = Registry.new('SpawnPoint', { label = 'spawn point', store = registered, scoped = true, same = false })

local callable = InteractSpec.callable   -- a function, or one handed over an export

--- A registered point as a choice for this character, or nil when its canUse says no (or errs: fails closed).
local function registeredChoice(key, rec, charId)
    if rec.canUse then
        local ok, yes = pcall(rec.canUse, charId)
        if not ok then
            print(('^3[whip_core] spawn point %s: canUse failed: %s^0'):format(key, tostring(yes)))
            return nil
        end
        if yes ~= true then return nil end
    end
    return { id = 'res:' .. key, kind = 'preset', label = rec.label, x = rec.x, y = rec.y, z = rec.z, heading = rec.heading }
end

--- RegisterSpawnPoint's body: (true) or (false, why).
function SpawnChoices.register(owner, id, def)
    if type(id) ~= 'string' or #id > 24 or not id:match('^[%w_%-]+$') then
        return false, 'a spawn point id is letters, digits, - and _ (at most 24)'
    end
    if type(def) ~= 'table' or callable(def) then return false, 'a spawn point is { label, pos, canUse? }' end
    local pos = def.pos
    local kind = type(pos)
    if kind ~= 'table' and kind ~= 'vector3' and kind ~= 'vector4' then
        return false, 'pos is a vector4 (or vector3) where they arrive'
    end
    local x, y, z = num(pos.x), num(pos.y), num(pos.z)
    if not (x and y and z) then return false, 'pos is a vector4 (or vector3) where they arrive' end
    if x < -4000 or x > 8000 or y < -7000 or y > 8000 or z < -200 or z > 2000 then return false, 'pos is outside the map' end
    if def.label ~= nil and type(def.label) ~= 'string' then return false, 'label is text' end
    if def.canUse ~= nil and not callable(def.canUse) then return false, 'canUse is a function(charId) that answers true' end
    local key = spawnReg:keyOf(owner, id)
    if #key + 4 > SpawnChoices.ID_MAX then   -- 'res:' .. key
        return false, ('"%s" and the resource name together are longer than %d characters: use a shorter id'):format(id, SpawnChoices.ID_MAX - 4)
    end
    if registered[key] == nil then
        local n = 0
        for _ in pairs(registered) do n = n + 1 end
        if n >= MAX_REGISTERED then return false, ('at most %d spawn points are registered at once'):format(MAX_REGISTERED) end
    end
    local label = def.label and Sanitize.string(def.label, 40, '') or ''
    return spawnReg:add(owner, id, {
        label = label ~= '' and label or id,
        x = x, y = y, z = z, heading = (num(pos.w) or num(def.heading) or 0.0) % 360.0,
        canUse = def.canUse,
    })
end

--- RemoveSpawnPoint's body: only the caller's own.
function SpawnChoices.remove(owner, id)
    if type(id) ~= 'string' then return false, 'a spawn point id is text' end
    return spawnReg:remove(owner, id)
end

--- Add a spawn point to the picker, beside config.lua's. RegisterSpawnPoint(id, { label, pos, canUse? }) ->
--- true | false, why. The same id again replaces it; it goes when your resource stops.
exports('RegisterSpawnPoint', function(id, def)
    return SpawnChoices.register(Registry.caller(), id, def)
end)

--- Take one of yours out: RemoveSpawnPoint(id) -> true | false, why.
exports('RemoveSpawnPoint', function(id)
    return SpawnChoices.remove(Registry.caller(), id)
end)

local function presetById(id)
    for _, p in ipairs(Config.SpawnPoints or {}) do
        if type(p) == 'table' and p.id == id then return presetChoice(p) end
    end
    return nil
end

--- A property as a choice: inside, at its visit point, facing in from its nearest front door. nil when it has no
--- inside to stand in (a unit not resolved yet), or its pack is not running.
---@param rec table|nil  the live record (Properties.get)
local function propertyChoice(rec)
    if not rec or rec.active == false then return nil end
    local w = rec.world
    local v = w and w.visit
    if not (v and num(v.x) and num(v.y) and num(v.z)) then return nil end
    local heading, best = 0.0, nil
    for _, d in ipairs(w.doors or {}) do
        if d.role == 'entrance' then
            local dist = (d.x - v.x) ^ 2 + (d.y - v.y) ^ 2
            if not best or dist < best then
                best = dist
                heading = headingOf(v.x - d.x, v.y - d.y)
            end
        end
    end
    return {
        id = 'property:' .. tostring(rec.propertyId), kind = 'property',
        label = rec.name or rec.label or 'Property',
        x = v.x, y = v.y, z = v.z, heading = heading,
    }
end

--- Every place a character may arrive, in the order the picker lists them.
---@param row table  their characters row: charId, x, y, z, heading (Character.list)
---@return table[]
function SpawnChoices.list(row)
    local d = Config.DefaultSpawn
    local out = {
        {
            id = 'last', kind = 'last', label = 'Last location',
            x = num(row.x) or d.x, y = num(row.y) or d.y, z = num(row.z) or d.z,
            heading = num(row.heading) or d.w,
        },
    }
    for _, p in ipairs(Config.SpawnPoints or {}) do
        local c = presetChoice(p)
        if c then out[#out + 1] = c end
    end
    local charId = tonumber(row.charId)
    -- The resources' own, by resource then id (the same order every time).
    local keys = {}
    for key in pairs(registered) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local c = registeredChoice(key, registered[key], charId)
        if c then out[#out + 1] = c end
    end
    if charId and Properties and Properties.forCharacter then
        local held = Properties.forCharacter(charId)
        for _, list in ipairs({ held.owned, held.keys }) do
            for _, id in ipairs(list) do
                local c = propertyChoice(Properties.get(id))
                if c then out[#out + 1] = c end
            end
        end
    end
    return out
end

--- Where a choice puts this character now, read again live. nil for 'last' (their own position stands).
---@param charId number
---@param spawnId string|nil
---@return vector4|nil at, string|nil why  why: the choice is no longer theirs to make
function SpawnChoices.resolve(charId, spawnId)
    if spawnId == nil or spawnId == '' or spawnId == 'last' then return nil end
    local c
    local presetId = spawnId:match('^preset:(.+)$')
    local propertyId = tonumber(spawnId:match('^property:(%d+)$'))
    local resKey = spawnId:match('^res:(.+)$')
    if resKey then
        local rec = registered[resKey]
        if not rec then return nil, 'That spawn point is not there any more' end
        c = registeredChoice(resKey, rec, charId)
        if not c then return nil, 'That spawn point is not yours to choose' end
    elseif presetId then
        c = presetById(presetId)
        if not c then return nil, 'That spawn point is not there any more' end
    elseif propertyId then
        local rec = Properties.get(propertyId)
        if not rec or not Properties.hasAccess(propertyId, charId) then
            return nil, 'You do not have a key to that property any more'
        end
        c = propertyChoice(rec)
        if not c then return nil, 'That property cannot be arrived at right now' end
    else
        return nil, 'That spawn is not one of yours'
    end
    return vector4(c.x + 0.0, c.y + 0.0, c.z + 0.0, c.heading + 0.0)
end
