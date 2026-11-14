-- ============================================
-- Blips — map markers from the server
-- ============================================
--
-- A blip a resource puts on some players' maps from SERVER code: where the package is, the drop-off,
-- a meeting point. The same rules as ShowPlayerText and the runtime points:
--
--   exports.whip_core:ShowBlip(audience, 'dropoff', {
--       coords = vector3(x, y, z), label = 'Drop-off', sprite = 1, color = 5,
--       route = true, radius = 25.0, tag = 'run:42' })
--   exports.whip_core:HideBlip('dropoff')
--   exports.whip_core:SetPlayerWaypoint(source, vector3(x, y, z))
--
--   * WHO SEES IT: an audience (server/audience.lua): 'everyone', { people = { serverId |
--     { charId = n } } }, or a job's people, { job = 'police', onDuty = true }. A character named by
--     charId sees it whenever they are on, after a relog too; a job's people as they clock on and off.
--   * YOURS: ids are your resource's own (another resource's 'dropoff' is another blip). The same id
--     again MOVES or changes that blip. Yours go when your resource stops, and with your run's tag.
--   * NO FRAME LOOP anywhere: the client makes a GTA blip when told, and remakes it only when told.
--
-- What a blip can say (all but coords optional):
--   coords      where (a vector3, or { x, y, z })
--   radius      metres: an AREA (a translucent circle on the map) instead of a point
--   sprite      GTA's blip icon number (1 = the plain dot, the default; 0 = none: an area alone, which
--               then has no name and no route, as those live on the dot)
--   color       GTA's blip colour number (5 = yellow, the objective colour)
--   label       what the map's legend calls it (at most 40 characters)
--   route       true: the GPS route to it, drawn on the map and the radar
--   shortRange  true: only on the radar when near (like a shop); default false: always shown
--   scale       its size on the map, 0.3-2 (default 0.9)
--   flash       true: it flashes

Blips = {}

local MAX_LABEL = 40
local nextWire = 0
local live = {}   -- [wireId] = the record up now (what a loaded character is sent)

local function num(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end

local function readCoords(c)
    if type(c) ~= 'table' and type(c) ~= 'vector3' and type(c) ~= 'vector4' then return nil end
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not (num(x) and num(y) and num(z)) then return nil end
    return x, y, z
end

--- A caller's spec, as the client draws it. Answers the wire table, or nil and why.
local function readSpec(spec)
    if type(spec) ~= 'table' then return nil, 'a blip is { coords, label, sprite, color, ... }' end
    local x, y, z = readCoords(spec.coords)
    if not x then return nil, 'coords must be a vector3 or { x, y, z }' end
    local w = { x = x, y = y, z = z }
    if spec.radius ~= nil then
        local r = tonumber(spec.radius)
        if not num(r) or r < 1 or r > 5000 then return nil, 'radius is 1-5000 metres' end
        w.radius = r + 0.0
    end
    -- No icon is asked for: the dot, except for a bare area (no name, no route), which is the circle
    -- alone. A name and a route live on the dot, so an area with either gets one in its middle.
    local sprite = spec.sprite
    if sprite == nil then sprite = (w.radius and spec.label == nil and spec.route ~= true) and 0 or 1 end
    sprite = math.tointeger(tonumber(sprite))
    if not sprite or sprite < 0 or sprite > 1000 then return nil, 'sprite is a GTA blip icon number' end
    w.sprite = sprite
    local color = math.tointeger(tonumber(spec.color == nil and 5 or spec.color))
    if not color or color < 0 or color > 85 then return nil, 'color is a GTA blip colour number (0-85)' end
    w.color = color
    if spec.label ~= nil then
        if type(spec.label) ~= 'string' then return nil, 'label is text' end
        -- GTA reads ~x~ in a blip's name as a colour or a button: none of that from here.
        local clean = BubbleText.clean(spec.label, MAX_LABEL):gsub('~', '')
        if clean ~= '' then w.label = clean end
    end
    if spec.scale ~= nil then
        local s = tonumber(spec.scale)
        if not num(s) then return nil, 'scale is a number' end
        w.scale = math.max(0.3, math.min(2.0, s))
    end
    w.route = spec.route == true or nil
    w.shortRange = spec.shortRange == true or nil
    w.flash = spec.flash == true or nil
    return w
end

-- ============================================
-- Who has which on their map
-- ============================================

local function send(rec, src, on)
    if on then
        rec.sentTo[src] = true
        TriggerClientEvent('whip_core:client:blip', src, rec.wireId, rec.wire)
    elseif rec.sentTo[src] then
        rec.sentTo[src] = nil
        TriggerClientEvent('whip_core:client:blip', src, rec.wireId, false)
    end
end

--- Bring every map up to date with one blip: on for its audience, off for anyone who left it.
local function push(rec)
    local want = Audience.sources(rec.audience)
    for src in pairs(rec.sentTo) do
        if not want[src] then send(rec, src, false) end
    end
    for src in pairs(want) do send(rec, src, true) end
end

local function drop(rec)
    rec.gone = true
    if live[rec.wireId] == rec then live[rec.wireId] = nil end
    for src in pairs(rec.sentTo) do send(rec, src, false) end
end

local reg = Registry.new('blip', {
    label = 'blip',
    scoped = true,
    releaseOrder = 10,   -- with what a player sees and presses: first in a run's release
    same = false,
    onAdd = function(_, rec, _, old)
        -- The same id again: the same blip on the client, moved or changed (and off for anyone no
        -- longer meant to see it).
        if old then
            old.gone = true
            rec.wireId, rec.sentTo = old.wireId, old.sentTo
        end
        live[rec.wireId] = rec
        push(rec)
    end,
    onRemove = function(_, rec) drop(rec) end,
})

--- Put a blip up (or move / change one already up with that id). Answers true, or false and why.
---@param owner string   Registry.caller()
---@param audience string|table
---@param id string|number
---@param spec table     see the header
function Blips.show(owner, audience, id, spec)
    local aud, awhy = Audience.read(audience, true, true)
    if not aud then return false, awhy or 'a blip needs an audience: \'everyone\', { people = {...} } or { job = ... }' end
    local wire, why = readSpec(spec)
    if not wire then return false, why end
    nextWire = nextWire + 1
    local rec = { owner = owner, id = id, audience = aud, wire = wire, wireId = nextWire, sentTo = {} }
    local tag = type(spec) == 'table' and spec.tag or nil
    local ok, rwhy = reg:add(owner, id, rec, tag ~= nil and { tag = tag } or nil)
    if not ok then return false, rwhy end
    return true
end

--- Take one of the caller's blips down. Answers true, or false and why.
function Blips.remove(owner, id)
    return reg:remove(owner, id)
end

--- The caller's blips: { { id, audience, coords, label } }.
function Blips.list(owner)
    local out = {}
    for _, key in ipairs(reg:keysOf(owner)) do
        local rec = reg:get(key)
        if rec then
            out[#out + 1] = { id = rec.id, audience = rec.audience, label = rec.wire.label,
                              coords = { x = rec.wire.x, y = rec.wire.y, z = rec.wire.z } }
        end
    end
    return out
end

--- The waypoint on one player's map (GTA's own: the purple one the player could set themselves).
--- Answers true, or false and why.
function Blips.waypoint(source, coords)
    local src = Sanitize.id(source)
    local player = src and Players[src]
    if not player or not player.charId then return false, 'no such player' end
    local x, y = readCoords(coords)
    if not x then return false, 'coords must be a vector3 or { x, y, z }' end
    TriggerClientEvent('whip_core:client:waypoint', src, x, y)
    return true
end

-- One waypoint per vehicle: GTA Online shares it between a vehicle's occupants; FiveM does not, so whip does: a player in a vehicle who sets or
-- clears their waypoint (client/blips.lua watches) has it set or cleared for every other player in the same one.
-- The vehicle is read here, from the server's own ped; the client only says what the waypoint is.
SecureEvent('whip_core:server:vehicleWaypoint', {
    rateLimit = 250,
    burst     = 4,
    params = {
        {'x',   'number', -20000, 20000},
        {'y',   'number', -20000, 20000},
        {'set', 'bool'},   -- false: cleared
    },
}, function(source, _, x, y, set)
    local veh = GetVehiclePedIsIn(GetPlayerPed(source), false)
    if not veh or veh == 0 then return end
    for _, id in ipairs(GetPlayers()) do
        local other = tonumber(id)
        if other and other ~= source and Players[other] and GetVehiclePedIsIn(GetPlayerPed(other), false) == veh then
            TriggerClientEvent('whip_core:client:vehicleWaypoint', other, x, y, set)
        end
    end
end)

-- A character coming on: every blip meant for them (a charId audience follows them across relogs).
Character.onLife('loaded', function(e)
    local src = e and e.source
    if not src then return end
    local list = {}
    for wireId, rec in pairs(live) do
        if Audience.has(rec.audience, src) then
            rec.sentTo[src] = true
            list[#list + 1] = { id = wireId, w = rec.wire }
        else
            rec.sentTo[src] = nil
        end
    end
    TriggerClientEvent('whip_core:client:blips', src, list)
end)

-- ...and going out: none of the last character's blips on the character screen.
Character.onLife('logout', function(e)
    local src = e and e.source
    if not src then return end
    for _, rec in pairs(live) do rec.sentTo[src] = nil end
    if e.why ~= 'disconnect' then TriggerClientEvent('whip_core:client:blips', src, {}) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    for _, rec in pairs(live) do rec.sentTo[src] = nil end
end)

-- A job's people as they are now: an officer who clocks on after a call
-- went out sees its mark, one who clocks off (or is fired) loses it. whip_core's own hook, never the
-- public job events.
local function jobMoved(e)
    for _, rec in pairs(live) do
        if Audience.isJob(rec.audience) and (type(e) ~= 'table' or e.key == nil or e.key == rec.audience.job) then push(rec) end
    end
end
for _, kind in ipairs({ 'clockedOn', 'clockedOff', 'hired', 'fired', 'deleted' }) do Jobs.onLife(kind, jobMoved) end

-- ============================================
-- Exports
-- ============================================

--- A blip on some players' maps: ShowBlip(audience, id, { coords, label, sprite, color, route, radius,
--- shortRange, scale, flash, tag }) -> true | false, why. The same id again moves or changes it.
exports('ShowBlip', function(audience, id, spec)
    local owner = Registry.caller()
    return Blips.show(owner, audience, id, spec)
end)

--- Take yours down, the pair of ShowBlip: HideBlip(id) -> true | false, why.
exports('HideBlip', function(id)
    local owner = Registry.caller()
    return Blips.remove(owner, id)
end)

--- GTA's waypoint on one player's map: SetPlayerWaypoint(source, coords) -> true | false, why.
exports('SetPlayerWaypoint', function(source, coords)
    return Blips.waypoint(source, coords)
end)
