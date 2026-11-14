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
-- 'preset:<id>' or 'property:<propertyId>'. Only a name: the picker shows the name and its kind's icon (Josh).

SpawnChoices = {}

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
    if presetId then
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
