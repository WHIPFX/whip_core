-- ============================================
-- Dev Tools — the Object Viewer's options (server side)
-- ============================================
--
-- G on the thing the object viewer has picked out opens a list of what can be done to it, on the right of the
-- screen (tools/ov_panel.lua, html/js/ov-panel.js). This file is that list's server half: what the thing is
-- (whip's own or the game's, whose car, which player) and every option that has to be done here.
--
-- What it reuses rather than repeats: the Vehicle Manager's calls (Vehicles.despawnToGarage, Vehicles.delete,
-- VehicleStats.set, Vehicles.transferOwner), the Player Manager's kick and ban (the client sends those events
-- itself), death's MarkPlayerAlive, the escort (ForceEscort), the emote list (EmoteList).
--
-- THE THING ON THE WIRE (`ref`): { net = netId } for an entity the network knows, { sid = serverId } for a player.
-- Something only the admin's game has (a map prop) never comes here: its options are the client's own.
--
-- WHAT RUNS WHERE. Hiding, invincibility, freezing, exploding, burning and killing only take on the game that owns
-- the entity (no server native does them). A one-off goes to the owner (`toOwner`); on GTA V Enhanced a car's repair,
-- tyres and engine are done by the server itself (`carEffect`, CAR_ON_SERVER). A hold (hidden, invincible,
-- frozen) is kept on the entity as a bitmask (ENTITY_OV_HOLD_KEY), so it follows the entity to whoever owns it next
-- (client/ov_effects.lua). A player's own holds (frozen, no combat) go to that player's game, which keeps them.
--
-- WHO. A full admin (whip.devtools), and a Dungeon Master (Dungeon Mode, director.live: the world builder on the world,
-- server/director/live.lua), who has every option but the ones that last (PERMANENT below: a full admin's only).
-- Every option used is logged on the user's timeline, and on the player's when it was used on one.

local OV_ACE = 'whip.devtools'
local LIVE = 'director.live'   -- (full admins hold it too: server/permissions.lua)

--- What lasts past a restart: a full admin's alone. (Kick and ban, the inventory, the trunk and the glovebox are
--- their own events, gated there. Repair is a full admin's on a player's saved car only: veh.fix below. Heal and
--- Armour are saved with the character but stay open to a Dungeon Master: Josh, 1 Nov.)
local PERMANENT = {
    ['veh.garage'] = true, ['veh.stat'] = true, ['veh.delete'] = true, ['veh.owner'] = true, ['veh.own'] = true,
    ['ply.stat'] = true, ['ply.creator'] = true, ['ply.walk'] = true,
    -- A ground item is saved as it lies: moved, changed or taken away, it stays so.
    ['pile.place'] = true, ['pile.item'] = true, ['pile.amount'] = true, ['pile.remove'] = true,
}

local fxHolds   -- (below, with the effects: a prop's or a ground item's effect switches, for describe)

local HIDDEN, INVINCIBLE, FROZEN = 1, 2, 4
local HOLD_BIT = { hidden = HIDDEN, invincible = INVINCIBLE, frozen = FROZEN }

local holds = {}    -- [entity] = the bitmask (the truth the bag follows)
local pholds = {}   -- [serverId] = { frozen, noCombat }
local models = {}   -- [serverId] = the model an admin put them in (Change Model), until put back

Sentinel.watch({
    key = ENTITY_OV_HOLD_KEY, family = 'entity', owner = 'whip_core',
    truth = function(entity) return holds[entity] end,
})

--- A removed entity's holds go with it. Listened for only while there are any: the server hears of every entity
--- removed, GTA's traffic and people included (hundreds a minute while someone drives), and every one heard costs the
--- runtime a coroutine (Josh's server profile, 11 Nov: a fifth of the server's time with one player driving).
local removedHandler = nil
local function hearRemoved()
    if next(holds) ~= nil then
        if not removedHandler then
            removedHandler = AddEventHandler('entityRemoved', function(entity)
                if holds[entity] == nil then return end
                holds[entity] = nil
                hearRemoved()
            end)
        end
    elseif removedHandler then
        RemoveEventHandler(removedHandler)
        removedHandler = nil
    end
end

local function forget(src)
    pholds[src], models[src] = nil, nil
end
AddEventHandler('playerDropped', function() forget(source) end)
-- A character swap is someone else: none of the last one's holds.
Character.onLife('logout', function(e) if e and e.source then forget(e.source) end end)

-- ============================================
-- What it is
-- ============================================

local function unsigned(h)
    h = math.tointeger(h) or 0
    if h < 0 then h = h + 0x100000000 end
    return h
end

--- The entity a ref names, and the player when it is one: entity, serverId|nil. nil when it is gone.
local function resolve(ref)
    if type(ref) ~= 'table' then return nil end
    local sid = Sanitize.id(ref.sid)
    if sid then
        if not Players[sid] then return nil end
        local ped = GetPlayerPed(sid)
        if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end
        return ped, sid
    end
    local net = Sanitize.id(ref.net)
    if not net or net > 65535 then return nil end
    local ent = NetworkGetEntityFromNetworkId(net)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    return ent, nil
end

--- A thing the server has no entity for, as a game names it: { kind = 'set', wire, i } (a prop set's piece: each game
--- makes its own copy) or { kind = 'map', map } (the map's own prop: each game's from the map, { model = its hash, name,
--- x, y, z, rx, ry, rz }, read again where it is used: server/director/live.lua). nil: not one of them.
local function otherOf(ref)
    if type(ref) ~= 'table' then return nil end
    if ref.wire ~= nil then
        local wire = Sanitize.id(ref.wire)
        if not wire or not PropSets.byWire(wire) then return nil end
        return { kind = 'set', wire = wire, i = Sanitize.id(ref.i) or 1 }
    end
    if type(ref.map) == 'table' then return { kind = 'map', map = ref.map } end
    if ref.ground ~= nil then
        local id = Sanitize.id(ref.ground)
        local row = id and GroundItems.getById(id)
        if not row then return nil end
        return { kind = 'pile', id = id, row = row }
    end
    return nil
end

--- A whip car the server saves (not a street car whip only noticed, nor a temporary one): its id.
local function savedCar(entity)
    local vid = Vehicles.getEntityVehicleId(entity)
    local def = vid and Vehicles.getDef(vid)
    if def and not def.session then return vid end
    return nil
end

--- Is this ped one whip's own systems make and keep (a shopkeeper, a Director or lore NPC)?
local function whipNpc(entity)
    return (Npcs and Npcs.by('entity', entity)) and true or false
end

--- Everyone online, the asker first: for an owner picker. { sid, name, charId }.
local function onlineList(source)
    local out = {}
    for sid, p in pairs(Players) do
        if p.charId then out[#out + 1] = { sid = sid, name = p.fullName or ('Player ' .. sid), charId = p.charId, me = sid == source } end
    end
    table.sort(out, function(a, b)
        if a.me ~= b.me then return a.me end
        return tostring(a.name) < tostring(b.name)
    end)
    return out
end

local function vehicleStats(vehicleId)
    local values = VehicleStats.getAll(vehicleId) or {}
    local out = {}
    for _, d in ipairs(VehicleStats.getStatDefs()) do
        out[#out + 1] = { name = d.name, min = d.min, max = d.max, value = values[d.name] }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function playerStats(sid)
    local values = Stats.getAll(sid) or {}
    local out = {}
    for _, d in ipairs(Stats.listDefs()) do
        out[#out + 1] = { name = d.name, min = d.min, max = d.max, value = values[d.name] }
    end
    return out
end

--- What the panel shows about the thing: its kind, whose, its holds, and what its pages need.
local function describe(source, entity, sid)
    if sid then
        local p = Players[sid]
        local h = pholds[sid] or {}
        return {
            kind = 'player', whip = true, sid = sid, name = p.fullName, charId = p.charId, userId = p.userId,
            dead = p.isDead == true, me = sid == source,
            holds = { frozen = h.frozen == true, noCombat = h.noCombat == true },
            model = models[sid], stats = playerStats(sid),
        }
    end
    local etype = GetEntityType(entity)
    if etype == 2 then
        local vid = Vehicles.getEntityVehicleId(entity)
        local v = vid and Vehicles.context(vid)
        local mask = holds[entity] or 0
        local out = {
            kind = 'vehicle', whip = v ~= nil and not v.session, temp = v ~= nil and v.temp == true,
            vehicleId = v and vid or nil, plate = v and v.plate or GetVehicleNumberPlateText(entity),
            holds = { hidden = mask & HIDDEN ~= 0, invincible = mask & INVINCIBLE ~= 0, frozen = mask & FROZEN ~= 0 },
            players = onlineList(source),
        }
        if v and out.whip then
            out.owner = v.owner and v.owner.charId and {
                charId = v.owner.charId,
                name = v.owner.name or (ResolveCharNames({ v.owner.charId }) or {})[v.owner.charId],
            } or nil
            out.state, out.garage = v.state, v.garage
            out.stats = vehicleStats(vid)
            out.locked = Vehicles.isLocked(vid) == true   -- (past its lock is a full admin's: tools/ov_panel.lua)
        end
        return out
    elseif etype == 1 then
        if IsPedAPlayer(entity) then return nil end   -- (a player comes by sid)
        return { kind = 'npc', whip = whipNpc(entity), dead = GetEntityHealth(entity) <= 0 }
    end
    -- A networked object (another resource's, or GTA's): its holds, as a car's.
    local mask = holds[entity] or 0
    return { kind = 'object', whip = false, prop = 'net', holds = { hidden = mask & HIDDEN ~= 0, frozen = mask & FROZEN ~= 0 } }
end

--- What the panel shows about a thing the server has no entity for (otherOf): a prop set's piece (one made in Dungeon
--- Mode is `live`, with its switches) or the map's own prop.
local function describeOther(source, o)
    if o.kind == 'set' then
        local live = DirectorLive and DirectorLive.cardOfWire(source, o.wire) or nil
        return { kind = 'object', whip = false, prop = 'set', live = live, holds = live and { solid = live.solid } or {} }
    end
    if o.kind == 'pile' then
        local r = o.row
        local def = Config.Items[r.item]
        local by = r.createdBy and ((PlayersByCharId[r.createdBy] and PlayersByCharId[r.createdBy].fullName)
            or (ResolveCharNames({ r.createdBy }) or {})[r.createdBy]) or nil
        return { kind = 'object', whip = true, prop = 'pile', holds = {},
                 pile = { id = o.id, item = r.item, label = def and def.name or r.item, amount = r.amount or 1,
                          stack = def ~= nil and def.stack == true, max = def and def.maxStack or 1, by = by, at = r.createdAt } }
    end
    return { kind = 'object', whip = false, prop = 'map', holds = {} }
end

--- What made it, when whip did: the card's Source line (tools/objectviewer.lua). nil: not whip's (the card keeps the
--- game's own answer: a GTA spawn, a script).
local function originOf(entity)
    local etype = GetEntityType(entity)
    if etype == 2 then
        local vid = Vehicles.getEntityVehicleId(entity)
        local def = vid and Vehicles.getDef(vid)
        if def then
            if def.temp then return ('%s (temporary car #%d)'):format(tostring(def.temp), vid) end
            if def.session then return ('GTA, noticed by whip_core (street car #%d)'):format(vid) end
            return ('whip_core (saved car #%d)'):format(vid)
        end
    elseif etype == 1 and Npcs then
        local npcId = Npcs.by('entity', entity)
        local n = npcId and Npcs.get(npcId)
        if n then
            local what = n.lore and 'lore character' or (type(n.tag) == 'string' and n.tag:find('^run:')) and 'Director NPC' or 'NPC'
            return ('%s (%s #%d)'):format(tostring(n.owner or 'whip_core'), what, npcId)
        end
    end
    return nil
end

SecureCallback('whip_core:ov:origin', {
    ace = OV_ACE,
    whileDead = true,
    rateLimit = 100,
    burst = 10,
    params = { { 'net', 'id' } },
}, function(_, _, net)
    if net > 65535 then return false, 'No such entity' end
    local ent = NetworkGetEntityFromNetworkId(net)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return false, 'It is not there any more' end
    return originOf(ent) or false
end)

SecureCallback('whip_core:ov:describe', {
    permission = LIVE,
    whileDead = true,
    rateLimit = 200,
    burst = 5,
    params = { { 'ref', 'any' } },
}, function(source, _, ref)
    local entity, sid = resolve(ref)
    if not entity then
        local o = otherOf(ref)
        if not o then return false, 'It is not there any more' end
        o.ref = ref
        local d = describeOther(source, o)
        d.admin = DevTools.hasAce(source, OV_ACE) == true
        fxHolds(d, o)
        return d
    end
    local d = describe(source, entity, sid)
    if not d then return false, 'It is not there any more' end
    if d.kind == 'object' then fxHolds(d, entity) end
    -- `admin`: the options that last are open (greyed otherwise). `live`: a Dungeon Master made it (whose, and whether
    -- this one may remove it).
    d.admin = DevTools.hasAce(source, OV_ACE) == true
    d.live = DirectorLive and not sid and DirectorLive.cardOf(source, entity) or nil
    -- A live NPC's own settings: its switches, and who it may go for or follow.
    if d.live and d.kind == 'npc' then
        d.holds = DirectorLive.holdsOf(DirectorLive.byEntity(entity))
        d.players = onlineList(source)
    end
    -- A live car's Key settings (its players list is every car's).
    if d.live and d.kind == 'vehicle' then d.carKey = DirectorLive.keyOf(DirectorLive.byEntity(entity)) end
    return d
end)

-- ============================================
-- Doing it
-- ============================================

--- A one-off for the game that owns the entity (the admin's when nobody does, which then asks for it).
local function toOwner(source, entity, what)
    local owner = NetworkGetEntityOwner(entity)
    if type(owner) ~= 'number' or owner <= 0 then owner = source end
    TriggerClientEvent('whip_core:client:ovEffect', owner, NetworkGetNetworkIdFromEntity(entity), what)
end

-- On GTA V Enhanced the server does these to a car itself (the vehicle natives it gained in November, citizenfx/rfc
-- #627), so a car nobody's game runs takes them too. On Legacy, and for anything else, it is the owner's (toOwner).
-- The server numbers a car's wheels 0 to its count, not by GTA's tyre numbers (0-5, 45, 47).
local CAR_ON_SERVER = GamePlatform.enhanced and {
    repair = function(veh)
        SetVehicleFixed(veh)
        SetVehicleDeformationFixed(veh)
        SetVehicleEngineHealth(veh, 1000.0)
        SetVehicleBodyHealth(veh, 1000.0)
        SetVehiclePetrolTankHealth(veh, 1000.0)
        SetVehicleDirtLevel(veh, 0.0)
        for wheel = 0, GetVehicleNumberOfWheels(veh) - 1 do SetVehicleTyreFixed(veh, wheel) end
    end,
    tyres = function(veh)
        local wheels = GetVehicleNumberOfWheels(veh)
        if wheels < 1 then error('the server does not know its wheels yet: try again in a moment', 0) end
        for wheel = 0, wheels - 1 do SetVehicleTyreBurst(veh, wheel, true, 1000.0) end
    end,
    -- Below 0 the engine is dead and burning; -4000 is as far as GTA goes.
    engine = function(veh) SetVehicleEngineHealth(veh, -4000.0) end,
} or {}

--- A one-off on a car: by the server where it can (CAR_ON_SERVER), otherwise sent to its owner. A native the server
--- refuses answers its own words (a range, a wheel), so the admin sees why.
---@return boolean ok
---@return string|nil why
local function carEffect(source, entity, what)
    local fn = CAR_ON_SERVER[what]
    if not fn then
        toOwner(source, entity, what)
        return true
    end
    local ok, err = pcall(fn, entity)
    if ok then return true end
    print(('[whip_core:objectviewer] %s on entity %d failed on the server: %s'):format(what, entity, tostring(err)))
    return false, 'The server could not do it: ' .. tostring(err)
end

--- Flip one hold bit on an entity; answers whether it is on now.
local function toggleHold(entity, bit)
    local mask = (holds[entity] or 0) ~ bit
    holds[entity] = mask ~= 0 and mask or nil
    hearRemoved()
    Sentinel.setEntityKey(entity, ENTITY_OV_HOLD_KEY, holds[entity])
    return mask & bit ~= 0
end

local function sendPlayerHolds(sid)
    local h = pholds[sid] or {}
    TriggerClientEvent('whip_core:client:ovHold', sid, { frozen = h.frozen == true, noCombat = h.noCombat == true })
end

--- Out of the seats, everyone in it (players and NPCs), straight onto the road.
local function ejectAll(veh)
    local n = 0
    for seat = -1, 15 do
        local ped = GetPedInVehicleSeat(veh, seat)
        if ped and ped ~= 0 then
            TaskLeaveVehicle(ped, veh, 16)
            n = n + 1
        end
    end
    return n
end

--- Fix: the car, and for a saved one its record as well (the dirt and the kept damage), or the next spawn puts
--- them back (the Vehicle Manager's Repair). The record only once the car took it.
---@return boolean ok
---@return string|nil why
local function fixCar(source, entity)
    local ok, why = carEffect(source, entity, 'repair')
    if not ok then return false, why end
    local vid = Vehicles.getEntityVehicleId(entity)
    if vid then
        local def = Vehicles.getDef(vid)
        if def and not def.session then
            local props = (Vehicles.context(vid) or {}).properties or {}
            props.dirtLevel = 0.0
            Vehicles.persist(vid, { properties = props })
        end
        VehicleDamage.clear(vid)
    end
    return true
end

--- What the /whip Vehicles page (server/vehicle_manager.lua) does to a car in the world the way this file does, rather
--- than again: a one-off (on the server, or the owning game), the repair, everyone out, and the frozen hold (which
--- follows the car to whoever owns it next).
ObjectViewer = {
    carEffect = carEffect,
    fixCar = fixCar,
    ejectAll = ejectAll,
    toggleFrozen = function(entity) return toggleHold(entity, FROZEN) end,
    isFrozen = function(entity) return ((holds[entity] or 0) & FROZEN) ~= 0 end,
}

--- A car out of the world (Vehicles.removeFromWorld: whip's one way, its record let go of and a street car deleted).
--- One with no record: deleted. Answers true, or false and why (the record refused).
local function takeAway(entity)
    local held = Vehicles.getEntityVehicleId(entity)
    if not held then DeleteEntity(entity) return true end
    return Vehicles.removeFromWorld(held)
end

--- A street car (or one whip only noticed) made a saved car of `ownerSid`'s, where it stands: the record first, so
--- nothing is lost if that fails; then this car goes and theirs comes out in its place.
local function makeOwned(_, entity, ownerSid, model, props)
    local owner = Players[ownerSid]
    if not owner then return false, 'They are not loaded in' end
    if type(model) ~= 'string' or model == '' or unsigned(GetHashKey(model)) ~= unsigned(GetEntityModel(entity)) then
        return false, 'Could not tell which model it is'
    end
    local at, heading = GetEntityCoords(entity), GetEntityHeading(entity)
    local held = Vehicles.getEntityVehicleId(entity)
    -- Its plate if no record holds it (a street car whip noticed holds its own: that one gets a new plate).
    local plate = Vehicles.normalisePlate(GetVehicleNumberPlateText(entity) or '')
    if held or (plate and Vehicles.getByPlate(plate)) then plate = nil end

    local vehicleId, err = Vehicles.createOwned(ownerSid, { model = model, plate = plate,
        properties = type(props) == 'table' and props or nil })
    if not vehicleId then return false, err or 'It could not be made theirs' end

    local removed = takeAway(entity)
    -- Still there (busy mid-change, or a player's game kept the car it owns): theirs waits in the garage rather than
    -- coming out inside this one
    if DoesEntityExist(entity) and GetEntityModel(entity) ~= 0 then removed = false end
    local name = owner.fullName or ('Player ' .. ownerSid)
    if not removed then
        return true, ('Vehicle #%d is %s\'s now, waiting in their garage (this car could not be taken away)'):format(vehicleId, name)
    end
    local v = Vehicles.context(vehicleId)
    local out = Vehicles.retrieve(vehicleId, v and v.garage or nil)
    local spawned = out and Vehicles.spawn(vehicleId, at.x, at.y, at.z, heading)
    if not spawned then
        return true, ('Vehicle #%d is %s\'s now, waiting in their garage (it could not come out here)'):format(vehicleId, name)
    end
    return true, ('Vehicle #%d is %s\'s now'):format(vehicleId, name)
end

local WALKS = {}
for _, w in ipairs(EmoteList and EmoteList.walks or {}) do WALKS[w.cmd] = true end
local EMOTES = {}
for _, e in ipairs(EmoteList and EmoteList.emotes or {}) do EMOTES[e.cmd] = true end

--- Every option done here: fn(source, entity, sid, arg) -> ok, message, extra. `kind` is what it takes.
local ACTIONS = {}

-- ---- whip's own cars ----
--
-- (Kind 'saved': misfit has found each one's id before it runs.)

ACTIONS['veh.garage'] = { kind = 'saved', fn = function(_, entity)
    local vid = savedCar(entity) --[[@as number]]
    local ok, err = Vehicles.despawnToGarage(vid)
    if not ok then return false, err or 'It could not be put away' end
    return true, ('Vehicle #%d is back in its garage'):format(vid)
end }

ACTIONS['veh.stat'] = { kind = 'saved', fn = function(_, entity, _, arg)
    local vid = savedCar(entity) --[[@as number]]
    local stat = type(arg) == 'table' and Sanitize.key(arg.stat, 40)
    local value = type(arg) == 'table' and tonumber(arg.value)
    if not stat or not value or value ~= value then return false, 'A stat and a number' end
    local def = Vehicles.getDef(vid)
    local carried = def and type(def.vehStats) == 'table' and def.vehStats[stat] ~= nil
    if not VehicleStats.isRegistered(stat) and not carried then return false, ('There is no vehicle stat "%s"'):format(stat) end
    local ok, err = VehicleStats.set(vid, stat, value, 'ov:admin')
    if ok == false then return false, err end
    return true, ('%s set to %s'):format(stat, tostring(VehicleStats.get(vid, stat))), { stats = vehicleStats(vid) }
end }

ACTIONS['veh.delete'] = { kind = 'saved', fn = function(source, entity)
    local vid = savedCar(entity)
    local ok, err = Vehicles.delete(vid)
    if not ok then return false, err or 'It could not be deleted' end
    print(('[whip_core:objectviewer] %s deleted vehicle #%d'):format(tostring((Players[source] or {}).fullName), vid))
    return true, ('Vehicle #%d deleted'):format(vid), { gone = true }
end }

ACTIONS['veh.owner'] = { kind = 'saved', fn = function(_, entity, _, arg)
    local vid = savedCar(entity) --[[@as number]]
    local charId = type(arg) == 'table' and Sanitize.id(arg.charId)
    if not charId then return false, 'Pick who it goes to' end
    local ok, err = Vehicles.transferOwner(vid, charId)
    if not ok then return false, err end
    local name = (ResolveCharNames({ charId }) or {})[charId] or ('character #' .. charId)
    return true, ('Vehicle #%d is %s\'s now'):format(vid, name)
end }

-- ---- any car ----

-- A player's own saved car keeps its repair in its record, which lasts: a full admin's (Josh, 1 Nov). A street, temp or
-- Dungeon car is anyone's here. (Heal and Armour stay open to a Dungeon Master: Josh, 1 Nov.)
ACTIONS['veh.fix'] = { kind = 'vehicle', fn = function(source, entity)
    if savedCar(entity) and not DevTools.hasAce(source, OV_ACE) then
        return false, 'Only an admin can repair a player\'s own car: it lasts past a restart'
    end
    local ok, why = fixCar(source, entity)
    if not ok then return false, why end
    return true, 'Repaired'
end }

ACTIONS['veh.explode'] = { kind = 'vehicle', fn = function(source, entity)
    toOwner(source, entity, 'explode')
    return true, 'Boom'
end }

ACTIONS['veh.eject'] = { kind = 'vehicle', fn = function(_, entity)
    local n = ejectAll(entity)
    if n == 0 then return false, 'Nobody is in it' end
    return true, n == 1 and 'One out' or (n .. ' out')
end }

--- A Dungeon Master's car or NPC goes the way it was made (its maker's, or an admin's to remove): true, or false and why.
--- nil: it is not one.
local function removeLive(source, entity)
    local t = DirectorLive and DirectorLive.byEntity(entity)
    if not t then return nil end
    local ok, why = DirectorLive.remove(source, t.id)
    if not ok then return false, why end
    return true
end

ACTIONS['veh.remove'] = { kind = 'street', fn = function(source, entity)
    local live, lwhy = removeLive(source, entity)
    if live ~= nil then
        if not live then return false, lwhy end
        return true, 'Removed', { gone = true }
    end
    local ok, err = takeAway(entity)
    if not ok then return false, err or 'It could not be removed' end
    return true, 'Removed', { gone = true }
end }

ACTIONS['veh.own'] = { kind = 'street', fn = function(source, entity, _, arg)
    if type(arg) ~= 'table' then return false, 'Pick who it is for' end
    local sid = Sanitize.id(arg.sid)
    if not sid then return false, 'Pick who it is for' end
    local ok, msg = makeOwned(source, entity, sid, arg.model, arg.props)
    if not ok then return false, msg end
    return true, msg, { gone = true }
end }

for name, bit in pairs(HOLD_BIT) do
    ACTIONS['veh.' .. name] = { kind = 'saved', fn = function(_, entity)
        local on = toggleHold(entity, bit)
        return true, nil, { on = on }
    end }
end

-- ---- players ----

ACTIONS['ply.heal'] = { kind = 'player', fn = function(_, _, sid)
    if Players[sid].isDead then return false, 'They are down: Revive them' end
    Stats.set(sid, 'health', 1e9, 'ov:admin')
    return true, 'Health restored'
end }

ACTIONS['ply.armour'] = { kind = 'player', fn = function(_, _, sid)
    Stats.set(sid, 'armour', 1e9, 'ov:admin')
    return true, 'Armour restored'
end }

ACTIONS['ply.revive'] = { kind = 'player', fn = function(_, _, sid)
    local p = Players[sid]
    if not p.isDead then return false, 'They are not down' end
    MarkPlayerAlive(sid, p, 'revive:admin')
    TriggerClientEvent('whip_core:client:revive', sid)
    return true, 'Revived'
end }

ACTIONS['ply.kill'] = { kind = 'player', fn = function(_, _, sid)
    if Players[sid].isDead then return false, 'They are already down' end
    TriggerClientEvent('whip_core:client:devKillMe', sid)
    return true, 'Downed'
end }

ACTIONS['ply.fire'] = { kind = 'player', fn = function(_, _, sid)
    TriggerClientEvent('whip_core:client:ovSelf', sid, 'fire')
    return true, 'On fire'
end }

ACTIONS['ply.escort'] = { kind = 'player', fn = function(source, _, sid)
    local ok, why = ForceEscort(source, sid)
    if not ok then return false, why end
    return true, 'Escorting them'
end }

ACTIONS['ply.creator'] = { kind = 'player', fn = function(_, _, sid)
    if Players[sid].isDead then return false, 'They are down' end
    TriggerClientEvent('whip_core:client:ovSelf', sid, 'creator')
    return true, 'Their character editor is open'
end }

ACTIONS['ply.model'] = { kind = 'player', fn = function(_, _, sid, arg)
    ---@type string|false|nil
    local model = type(arg) == 'table' and arg.model
    if model ~= false then
        model = type(model) == 'string' and model:match('^[%w_]+$') and #model <= 40 and model or nil
        if not model then return false, 'Pick a model' end
    end
    models[sid] = model or nil
    TriggerClientEvent('whip_core:client:ovSelf', sid, 'model', model)
    return true, model and ('Wearing ' .. model) or 'Back in their own look', { model = models[sid] or false }
end }

ACTIONS['ply.walk'] = { kind = 'player', fn = function(_, _, sid, arg)
    local walk = type(arg) == 'table' and arg.walk
    if walk ~= false and not WALKS[walk] then return false, 'Pick a walk' end
    TriggerClientEvent('whip_core:client:ovSelf', sid, 'walk', walk)
    return true, walk and ('Walking ' .. walk) or 'Their normal walk'
end }

ACTIONS['ply.emote'] = { kind = 'player', fn = function(_, _, sid, arg)
    local cmd = type(arg) == 'table' and arg.cmd
    if cmd ~= false and not EMOTES[cmd] then return false, 'Pick an emote' end
    if Players[sid].isDead then return false, 'They are down' end
    TriggerClientEvent('whip_core:client:ovSelf', sid, 'emote', cmd)
    return true, cmd and ('Playing ' .. cmd) or 'Stopped'
end }

ACTIONS['ply.stat'] = { kind = 'player', fn = function(_, _, sid, arg)
    local stat = type(arg) == 'table' and Sanitize.key(arg.stat, 40)
    local value = type(arg) == 'table' and tonumber(arg.value)
    if not stat or not value or value ~= value then return false, 'A stat and a number' end
    local ok, err = Stats.set(sid, stat, value, 'ov:admin')
    if not ok then return false, err end
    return true, ('%s set to %s'):format(stat, tostring(Stats.get(sid, stat))), { stats = playerStats(sid) }
end }

for _, name in ipairs({ 'frozen', 'noCombat' }) do
    ACTIONS['ply.' .. name] = { kind = 'player', fn = function(_, _, sid)
        local h = pholds[sid] or {}
        h[name] = not h[name]
        pholds[sid] = (h.frozen or h.noCombat) and h or nil
        sendPlayerHolds(sid)
        return true, nil, { on = h[name] == true }
    end }
end

-- ---- NPCs ----

ACTIONS['npc.remove'] = { kind = 'npc', fn = function(source, entity)
    local live, lwhy = removeLive(source, entity)
    if live == false then return false, lwhy end
    if live == nil then DeleteEntity(entity) end
    return true, 'Removed', { gone = true }
end }

ACTIONS['npc.kill'] = { kind = 'npc', fn = function(source, entity)
    toOwner(source, entity, 'kill')
    return true, 'Killed'
end }

ACTIONS['npc.fire'] = { kind = 'npc', fn = function(source, entity)
    toOwner(source, entity, 'fire')
    return true, 'On fire'
end }

-- ---- networked objects (another resource's, or GTA's) ----

ACTIONS['obj.remove'] = { kind = 'object', fn = function(_, entity)
    DeleteEntity(entity)
    return true, 'Removed', { gone = true }
end }

for _, name in ipairs({ 'hidden', 'frozen' }) do
    ACTIONS['obj.' .. name] = { kind = 'object', fn = function(_, entity)
        return true, nil, { on = toggleHold(entity, HOLD_BIT[name]) }
    end }
end

--- Swap for a Dungeon prop: one of the new model where it stands, turned as it is (a prop made in Dungeon Mode: yours,
--- until a restart or Remove), and this one taken away.
ACTIONS['obj.swap'] = { kind = 'object', fn = function(source, entity, _, arg)
    if type(arg) ~= 'table' then return false, 'Pick a model' end
    local c, r = GetEntityCoords(entity), GetEntityRotation(entity, 2)
    local v, why = DirectorLive.make(source, { kind = 'prop', model = arg.model, label = arg.label,
        coords = { x = c.x, y = c.y, z = c.z, heading = r.z }, rot = { x = r.x, y = r.y } })
    if not v then return false, why end
    DeleteEntity(entity)
    return true, ('A %s in its place'):format(tostring(arg.label or arg.model)), { gone = true, made = v }
end }

-- ---- a Dungeon Master's NPC (server/director/live.lua): its maker's, or a full admin's ----

local function liveOf(entity) return DirectorLive and DirectorLive.byEntity(entity) end
local function whoName(source) return tostring((Players[source] or {}).fullName or ('player ' .. source)) end

--- A loaded player picked on a page: their server id, or nil.
local function pickedPlayer(arg)
    local sid = type(arg) == 'table' and Sanitize.id(arg.sid)
    return sid and Players[sid] and Players[sid].charId and sid or nil
end

ACTIONS['live.attack'] = { kind = 'live', fn = function(source, entity, _, arg)
    local sid = pickedPlayer(arg)
    if not sid then return false, 'Pick who they go for' end
    local ok, why = DirectorLive.setNpc(source, liveOf(entity), { hostileTo = { people = { sid } }, follow = false, flee = false },
        'set on them by Dungeon Master ' .. whoName(source))
    if not ok then return false, why end
    return true, ('Going for %s'):format(tostring(Players[sid].fullName))
end }

ACTIONS['live.follow'] = { kind = 'live', fn = function(source, entity, _, arg)
    local sid = pickedPlayer(arg)
    if not sid then return false, 'Pick who they follow' end
    local ok, why = DirectorLive.setNpc(source, liveOf(entity), { follow = sid, flee = false })
    if not ok then return false, why end
    return true, ('Following %s'):format(tostring(Players[sid].fullName))
end }

ACTIONS['live.calm'] = { kind = 'live', fn = function(source, entity)
    local ok, why = DirectorLive.setNpc(source, liveOf(entity), { hostileTo = false, follow = false, flee = false, attack = false })
    if not ok then return false, why end
    return true, 'Calm'
end }

ACTIONS['live.weapon'] = { kind = 'live', fn = function(source, entity, _, arg)
    ---@type string|false|nil
    local w = type(arg) == 'table' and arg.weapon
    if w ~= false then
        w = type(w) == 'string' and w:upper() or nil
        if not (w and w:match('^WEAPON_[%w_]+$') and #w <= 64) then return false, 'Pick a weapon' end
    end
    local ok, why = DirectorLive.rearm(source, liveOf(entity), w or false)
    if not ok then return false, why end
    return true, w and ('Holding ' .. (WeaponCatalog.title(WeaponCatalog.get(w)) or w)) or 'No weapon', { gone = true }
end }

-- Its switches: behaviour (guard or stand), and two conditions.
local LIVE_SWITCH = {
    guard      = function(on) return { behaviour = on and 'guard' or 'stand' } end,
    invincible = function(on) return { conditions = { invincible = on } } end,
    still      = function(on) return { conditions = { canMove = not on } } end,
}
for name, patchOf in pairs(LIVE_SWITCH) do
    ACTIONS['live.' .. name] = { kind = 'live', fn = function(source, entity)
        local t = liveOf(entity)
        local on = not (t and t[name] == true)
        local ok, why = DirectorLive.setNpc(source, t, patchOf(on), nil, { [name] = on })
        if not ok then return false, why end
        return true, nil, { on = on }
    end }
end

-- ---- a Dungeon Master's car: its Key settings (server/director/live.lua) ----

ACTIONS['live.key'] = { kind = 'liveCar', fn = function(source, entity, _, arg)
    -- (Refused after its key had moved, a cut that failed: how it stands now goes back with the refusal, so the page
    -- shows the truth, not what was asked: ov_panel.lua.)
    local ok, now, stands = DirectorLive.setKey(source, liveOf(entity), arg)
    if not ok then return false, now, stands and { carKey = stands } or nil end
    ---@cast now table
    local said = { none = 'No key', player = 'Its key is ' .. tostring(now.who) .. '\'s', ignition = 'Its key is in the ignition',
                   glovebox = 'Its key is in the glovebox', trunk = 'Its key is in the boot', ground = 'Its key is on the ground beside it' }
    return true, (said[now.where] or 'Saved') .. (now.locked and ', locked' or ''), { carKey = now }
end }

-- ---- a Dungeon Master's prop, and the map's own (server/director/live.lua): no entity here, `o` is otherOf's ----

local function liveProp(o) return DirectorLive and o and o.kind == 'set' and DirectorLive.byWire(o.wire) or nil end

--- A prop's set shown again (a change): each game's copy is a new object under a new wire id, which the options
--- follow (`rewire`) and Dungeon Mode's list too (`made`, its view now).
local function reshown(source, t, extra)
    extra = extra or {}
    local v = DirectorLive.viewOf(source, t)
    extra.rewire, extra.made = v.wire, v
    return extra
end

ACTIONS['live.propModel'] = { kind = 'dprop', fn = function(source, o, _, arg)
    if type(arg) ~= 'table' then return false, 'Pick a model' end
    local t = liveProp(o)
    local ok, why = DirectorLive.setProp(source, t, { model = arg.model, label = arg.label })
    if not ok then return false, why end
    return true, ('It is a %s now'):format(tostring(arg.label or arg.model)), reshown(source, t)
end }

ACTIONS['live.solid'] = { kind = 'dprop', fn = function(source, o)
    local t = liveProp(o)
    local on = not (t and t.solid ~= false)
    local ok, why = DirectorLive.setProp(source, t, { solid = on })
    if not ok then return false, why end
    return true, nil, reshown(source, t, { on = on })
end }

ACTIONS['live.propRemove'] = { kind = 'dprop', fn = function(source, o)
    local t = liveProp(o)
    local ok, why = DirectorLive.remove(source, t and t.id)
    if not ok then return false, why end
    return true, 'Removed', { gone = true }
end }

ACTIONS['live.restore'] = { kind = 'dprop', fn = function(source, o)
    local ok, why = DirectorLive.restore(source, liveProp(o))
    if not ok then return false, why end
    return true, 'The map\'s own is back', { gone = true }
end }

ACTIONS['map.hide'] = { kind = 'map', fn = function(source, o)
    local t, why = DirectorLive.hideMap(source, o.map)
    if not t then return false, why end
    return true, 'Hidden for everyone: Put back on the Dungeon Mode page brings it back', { gone = true }
end }

ACTIONS['map.take'] = { kind = 'map', fn = function(source, o)
    local v, why = DirectorLive.takeOver(source, o.map)
    if not v then return false, why end
    return true, 'A Dungeon prop now: yours to move, change or remove', { gone = true, made = v }
end }

ACTIONS['map.model'] = { kind = 'map', fn = function(source, o, _, arg)
    if type(arg) ~= 'table' then return false, 'Pick a model' end
    local v, why = DirectorLive.takeOver(source, o.map, arg.model, arg.label)
    if not v then return false, why end
    return true, ('A %s in its place, for everyone'):format(tostring(arg.label or arg.model)), { gone = true, made = v }
end }

-- ---- a ground item (server/ground.lua): saved as it lies, so all of these are a full admin's (PERMANENT) ----

--- `o` is otherOf's pile. Each takes the pile's pickup lock, so a player picking it up meanwhile is one or the other.
local function withPile(o, fn)
    if not GroundItems.tryLock(o.id) then return false, 'Someone is picking it up' end
    local ok, a, b, c = pcall(fn, GroundItems.getById(o.id))
    GroundItems.unlock(o.id)
    if not ok then print('[whip_core:objectviewer] a ground item option failed: ' .. tostring(a)) return false, 'That went wrong' end
    return a, b, c
end

local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end

--- On the item log: what an admin's change took away and brought in (an item made or gone on the ground).
local function logPile(source, event, item, amount, row, what)
    Log.write(nil, event, { itemKey = item, amount = amount, x = row.x, y = row.y, z = row.z,
        detail = ('%s by %s · on the ground'):format(what, whoName(source)) })
end

ACTIONS['pile.place'] = { kind = 'pile', fn = function(_, o, _, arg)
    arg = type(arg) == 'table' and arg or {}
    local x, y, z, h = tonumber(arg.x), tonumber(arg.y), tonumber(arg.z), tonumber(arg.heading) or 0.0
    if not (finite(x) and finite(y) and finite(z) and finite(h)) or math.abs(x --[[@as number]]) > 20000 or math.abs(y --[[@as number]]) > 20000 or z < -500 or z > 3000 then
        return false, 'That is not a place in the world'
    end
    return withPile(o, function(row)
        if not row then return false, 'It is not there any more' end
        local ok, why = GroundItems.place(o.id, x, y, z, h % 360.0, { rx = tonumber(arg.rx) or 0.0, ry = tonumber(arg.ry) or 0.0 })
        if not ok then return false, why end
        return true, 'It lies there now, for everyone'
    end)
end }

--- An NPC moved by hand (Dungeon Mode's markers on a run's or a script's NPC): one of whip's stands there from now on (its
--- post), or it would walk back to the old one. Another ped has no post: its new place is its owner game's to keep.
ACTIONS['npc.place'] = { kind = 'npc', fn = function(_, entity, _, arg)
    arg = type(arg) == 'table' and arg or {}
    local x, y, z, h = tonumber(arg.x), tonumber(arg.y), tonumber(arg.z), tonumber(arg.heading) or 0.0
    if not (finite(x) and finite(y) and finite(z) and finite(h)) or math.abs(x --[[@as number]]) > 20000 or math.abs(y --[[@as number]]) > 20000 or z < -500 or z > 3000 then
        return false, 'That is not a place in the world'
    end
    local id = Npcs.by('entity', entity)
    local info = id and Npcs.get(id)
    if not info then return true end
    local ok, why = Npcs.setState(info.owner, id, { post = { x = x, y = y, z = z, heading = h % 360.0 } }, 'moved in Dungeon Mode')
    if not ok then return false, why end
    return true, 'It stands there now'
end }

--- An item and how many, as an admin picked them: item, amount, or nil and why. One that does not stack is one.
local function pickedItem(arg)
    arg = type(arg) == 'table' and arg or {}
    local item = type(arg.item) == 'string' and arg.item or nil
    local def = item and Config.Items[item]
    if not def then return nil, 'Pick an item' end
    local amount = math.tointeger(tonumber(arg.amount)) or 1
    local max = def.stack and math.max(1, math.tointeger(tonumber(def.maxStack)) or 1000) or 1
    if amount < 1 or amount > max then return nil, max == 1 and ('%s does not stack: one only'):format(def.name or item)
        or ('1 to %d'):format(max) end
    return item, amount
end

ACTIONS['pile.item'] = { kind = 'pile', fn = function(source, o, _, arg)
    local item, amount = pickedItem(arg)
    if not item then return false, amount end
    return withPile(o, function(row)
        if not row then return false, 'It is not there any more' end
        local was = { item = row.item, amount = row.amount or 1 }
        -- (An item that is given its own metadata, a gun's serial, gets fresh metadata.)
        local gen = Inventory.MetaGenerators[item]
        local meta = gen and Inventory.runMetaGen(gen, item, Inventory.metaContext(nil, 'given')) or nil
        local ok, why = GroundItems.setItem(o.id, item, amount, meta)
        if not ok then return false, why end
        logPile(source, 'lost', was.item, was.amount, row, 'changed into ' .. item)
        logPile(source, 'gained', item, amount, row, 'changed from ' .. was.item)
        -- (Each game draws it again as the new item: its object here goes, and the options with it.)
        return true, ('It is %d %s now'):format(amount, Config.Items[item].name or item), { gone = true }
    end)
end }

ACTIONS['pile.amount'] = { kind = 'pile', fn = function(source, o, _, arg)
    local row0 = GroundItems.getById(o.id)
    if not row0 then return false, 'It is not there any more' end
    local _, amount = pickedItem({ item = row0.item, amount = type(arg) == 'table' and arg.amount })
    if type(amount) ~= 'number' then return false, amount end
    return withPile(o, function(row)
        if not row then return false, 'It is not there any more' end
        local was = row.amount or 1
        local ok, why = GroundItems.setAmount(o.id, amount)
        if not ok then return false, why end
        if amount > was then logPile(source, 'gained', row.item, amount - was, row, 'more on the pile')
        elseif amount < was then logPile(source, 'lost', row.item, was - amount, row, 'fewer on the pile') end
        return true, ('%d on it now'):format(amount)
    end)
end }

ACTIONS['pile.remove'] = { kind = 'pile', fn = function(source, o)
    return withPile(o, function(row)
        if not row then return false, 'It is not there any more' end
        local ok, why = GroundItems.delete(o.id)
        if not ok then return false, why end
        logPile(source, 'lost', row.item, row.amount or 1, row, 'taken away')
        return true, 'Removed', { gone = true }
    end)
end }

-- ---- effects on a prop or a ground item (server/director/live.lua): anyone's, until switched off ----

--- What an effect is on: { key, target, at, what } (an entity: the networked object; else otherOf's).
local function fxTargetOf(thing)
    if type(thing) == 'number' then
        local c = GetEntityCoords(thing)
        local net = NetworkGetNetworkIdFromEntity(thing)
        return { key = 'n:' .. net, target = { net = net }, at = { x = c.x, y = c.y, z = c.z }, what = 'an object' }
    end
    if thing.kind == 'pile' then
        local r = thing.row
        return { key = 'g:' .. thing.id, target = { ground = thing.id }, at = { x = r.x, y = r.y, z = r.z },
                 what = ('a ground item (%s)'):format(tostring(r.item)) }
    end
    if thing.kind == 'set' then
        local t = liveProp(thing)
        if t then return { key = 'l:' .. t.id, target = { live = t.id }, at = t.coords, what = ('a Dungeon prop (%s)'):format(t.model) } end
        local a = type(thing.ref) == 'table' and type(thing.ref.at) == 'table' and thing.ref.at or {}
        return { key = ('w:%d:%d'):format(thing.wire, thing.i), target = { wire = thing.wire, i = thing.i },
                 at = { x = tonumber(a.x) or 0.0, y = tonumber(a.y) or 0.0, z = tonumber(a.z) or 0.0 }, what = 'a script\'s prop' }
    end
    local m = thing.map
    local x, y, z = tonumber(m.x), tonumber(m.y), tonumber(m.z)
    if not (x and y and z) then return nil end
    return { key = ('m:%s:%.2f:%.2f:%.2f'):format(tostring(m.model), x, y, z), target = {}, at = { x = x, y = y, z = z },
             what = ('a map prop (%s)'):format(tostring(m.name or m.model)) }
end

for _, kind in ipairs({ 'smoke', 'sparks', 'flames', 'steam', 'light' }) do
    ACTIONS['fx.' .. kind] = { kind = 'fx', fn = function(source, thing)
        local on, why = DirectorLive.toggleEffect(source, fxTargetOf(thing), kind)
        if on == nil then return false, why end
        return true, nil, { on = on }
    end }
end

--- A real explosion where it stands, set off by the asker's game (the server makes none): it says where.
ACTIONS['fx.boom'] = { kind = 'fx', fn = function(_, thing)
    local ft = fxTargetOf(thing)
    if not ft then return false, 'Where?' end
    return true, 'Boom', { boom = ft.at }
end }

--- Its effects' switches, for the panel: merged into `holds`.
fxHolds = function(d, thing)
    if not DirectorLive then return end
    local ft = fxTargetOf(thing)
    if not ft then return end
    d.holds = d.holds or {}
    for k, on in pairs(DirectorLive.effectsOn(ft.key)) do d.holds['fx_' .. k] = on end
end

-- ---- a player: what a Dungeon Master makes for them (theirs, server/director/live.lua) ----

--- Somewhere for a car beside them: ahead of them, then to each side, then behind (the spot must be clear).
local function carSpots(ped)
    local c, h = GetEntityCoords(ped), GetEntityHeading(ped)
    local r = math.rad(h)
    local fx, fy = -math.sin(r), math.cos(r)
    local out = {}
    for _, o in ipairs({ { 4.5, 0 }, { 0, 4.0 }, { 0, -4.0 }, { -5.0, 0 } }) do
        local x = c.x + fx * o[1] + fy * o[2]
        local y = c.y + fy * o[1] - fx * o[2]
        out[#out + 1] = { x = x, y = y, z = c.z + 0.3, heading = h }
    end
    return out
end

ACTIONS['ply.car'] = { kind = 'player', fn = function(source, ped, sid, arg)
    local model = type(arg) == 'table' and type(arg.model) == 'string' and arg.model:lower() or nil
    if not (model and model:match('^[%w_]+$') and #model <= 64) then return false, 'Pick a car' end
    if GetVehiclePedIsIn(ped, false) ~= 0 then return false, 'They are in a car' end
    local why
    for _, at in ipairs(carSpots(ped)) do
        local v, w = DirectorLive.make(source, { kind = 'vehicle', model = model, coords = at,
            label = ('for %s'):format(tostring(Players[sid].fullName)) }, { forSource = sid })
        if v then return true, ('A %s beside %s, their key in their pocket'):format(model, tostring(Players[sid].fullName)) end
        why = w
    end
    return false, why or 'There is no room beside them'
end }

local HUNTERS = { 'g_m_y_lost_01', 'g_m_y_lost_02', 'g_m_y_ballaeast_01', 'g_m_y_famca_01', 'g_m_y_mexgoon_01', 'g_m_y_salvagoon_01' }
local HUNT_GUN = { pistol = 'WEAPON_PISTOL', smg = 'WEAPON_MICROSMG', rifle = 'WEAPON_ASSAULTRIFLE', shotgun = 'WEAPON_PUMPSHOTGUN' }
local HUNT_MAX, HUNT_REACH = 6, 80.0

--- NPCs sent after them, from the spots the Dungeon Master's game found on the ground round them (each within reach).
ACTIONS['ply.hunt'] = { kind = 'player', fn = function(source, ped, sid, arg)
    arg = type(arg) == 'table' and arg or {}
    local n = math.max(1, math.min(HUNT_MAX, math.tointeger(tonumber(arg.n)) or 2))
    local gun = arg.weapon == 'none' and nil or HUNT_GUN[arg.weapon] or HUNT_GUN.pistol
    local c = GetEntityCoords(ped)
    local spots = {}
    for _, s in ipairs(type(arg.spots) == 'table' and arg.spots or {}) do
        local x, y, z = tonumber(type(s) == 'table' and s.x), tonumber(type(s) == 'table' and s.y), tonumber(type(s) == 'table' and s.z)
        if x and y and z and #(vector3(x, y, z) - c) <= HUNT_REACH then spots[#spots + 1] = { x = x, y = y, z = z } end
        if #spots >= n then break end
    end
    if #spots == 0 then return false, 'No ground near them to send anyone from' end
    local who = tostring(Players[sid].fullName)
    local made = 0
    local why
    for i, s in ipairs(spots) do
        local face = math.deg(math.atan(-(c.x - s.x), c.y - s.y)) % 360.0
        local v, w = DirectorLive.make(source, { kind = 'npc', model = HUNTERS[(i - 1) % #HUNTERS + 1],
            coords = { x = s.x, y = s.y, z = s.z, heading = face }, label = ('after %s'):format(who) },
            { gun = gun, hostileTo = { people = { sid } }, because = 'sent after them by Dungeon Master ' .. whoName(source) })
        if v then made = made + 1 else why = w end
    end
    if made == 0 then return false, why or 'Nobody could be sent' end
    return true, ('%d sent after %s'):format(made, who)
end }

local KEYS = {}
for key in pairs(ACTIONS) do KEYS[#KEYS + 1] = key end

--- Does the option fit the thing (`other`: one the server has no entity for, otherOf's)? nil, or why not.
local function misfit(kind, entity, sid, other)
    if kind == 'dprop' then return liveProp(other) == nil and 'That is not a prop made in Dungeon Mode' or nil end
    if kind == 'map' then return not (other and other.kind == 'map') and 'That is not one of the map\'s props' or nil end
    if kind == 'pile' then return not (other and other.kind == 'pile') and 'That is not a ground item' or nil end
    if kind == 'fx' then
        if other then return nil end
        return not (entity and GetEntityType(entity) == 3) and 'Effects go on a prop or a ground item' or nil
    end
    if not entity then return 'That is not something the server can reach' end
    if kind == 'object' then return GetEntityType(entity) ~= 3 and 'That is not an object' or nil end
    if kind == 'player' then return not sid and 'That is not a player' or nil end
    if sid then return 'That is a player' end
    if kind == 'live' then
        local t = DirectorLive and DirectorLive.byEntity(entity)
        if not (t and t.kind == 'npc') then return 'That is not an NPC made in Dungeon Mode' end
        return nil
    end
    if kind == 'liveCar' then
        local t = DirectorLive and DirectorLive.byEntity(entity)
        if not (t and t.kind == 'vehicle') then return 'That is not a car made in Dungeon Mode' end
        return nil
    end
    local etype = GetEntityType(entity)
    if kind == 'npc' then
        if etype ~= 1 or IsPedAPlayer(entity) then return 'That is not an NPC' end
        -- (A Dungeon Master's NPC is whip's, made to be changed: it is theirs.)
        if whipNpc(entity) and not (DirectorLive and DirectorLive.byEntity(entity)) then
            return 'whip\'s own NPC: its system looks after it'
        end
        return nil
    end
    if etype ~= 2 then return 'That is not a vehicle' end
    if kind == 'saved' and not savedCar(entity) then return 'That is not one of whip\'s saved cars' end
    if kind == 'street' and savedCar(entity) then return 'That is one of whip\'s saved cars' end
    return nil
end

--- What it was done to, for the log: "Jo Bloggs (player 3)", "a car (sultan)", "an NPC".
local function logName(entity, sid)
    if sid then
        local p = Players[sid]
        return ('%s (player %d)'):format(tostring(p and p.fullName or '?'), sid), p and p.charId or nil
    end
    local etype = GetEntityType(entity)
    local t = DirectorLive and DirectorLive.byEntity(entity)
    local whose = t and (', made by ' .. tostring(t.by)) or ''
    if etype == 2 then return ('a car (%s%s)'):format(GetVehicleNumberPlateText(entity) or '?', whose) end
    if etype == 1 then return 'an NPC' .. (t and (' (made by ' .. tostring(t.by) .. ')') or '') end
    return 'an object'
end

SecureCallback('whip_core:ov:act', {
    permission = LIVE,
    whileDead = true,
    rateLimit = 150,
    burst = 8,
    params = { { 'ref', 'any' }, { 'action', 'enum', KEYS }, { 'arg', 'any' } },
}, function(source, _, ref, action, arg)
    if PERMANENT[action] and not DevTools.hasAce(source, OV_ACE) then
        return false, 'Only an admin can do that: it lasts past a restart'
    end
    local entity, sid = resolve(ref)
    local other = not entity and otherOf(ref) or nil
    if not entity and not other then return false, 'It is not there any more' end
    if other then other.ref = ref end
    local a = ACTIONS[action]
    local why = misfit(a.kind, entity, sid, other)
    if why then return false, why end
    -- Read before it is done (a removed car has no plate after).
    local what, charId, at
    if entity then
        what, charId = logName(entity, sid)
        at = GetEntityCoords(entity)
    elseif other and other.kind == 'set' then
        local t = liveProp(other)
        if t then what, at = ('a Dungeon prop (%s, made by %s)'):format(tostring(t.model), tostring(t.by)), t.coords
        else what, at = 'a script\'s prop', { x = 0.0, y = 0.0, z = 0.0 } end
    elseif other and other.kind == 'pile' then
        local r = other.row
        what, at = ('a ground item (%s x%d)'):format(tostring(r.item), r.amount or 1), { x = r.x, y = r.y, z = r.z }
    elseif other then
        local m = other.map
        what = ('a map prop (%s)'):format(tostring(type(m.name) == 'string' and m.name or m.model))
        at = { x = tonumber(m.x) or 0.0, y = tonumber(m.y) or 0.0, z = tonumber(m.z) or 0.0 }
    end
    local ok, msg, extra = a.fn(source, entity or other, sid, arg)
    -- (A refusal that says how things stand now, Key settings after a cut that failed, goes back with it: ov_panel.lua.)
    if not ok and extra ~= nil then return { ok = false, text = msg or 'That did not work', extra = extra } end
    if not ok then return false, msg or 'That did not work' end
    if DirectorLive then
        DirectorLive.log(source, ('used %s on %s%s'):format(action, what, msg and (': ' .. msg) or ''),
            { x = at.x, y = at.y, z = at.z }, charId)
    end
    return { ok = true, text = msg, extra = extra }
end)

-- ============================================
-- Move, for a player (tools/ov_move.lua)
-- ============================================
--
-- A car, an NPC or a prop the admin's game moves itself (it takes control). A player's ped is their own game's, so
-- it is moved here: about ten times a second while dragged.

local movedSaid = {}   -- ['src:sid'] = when a move of theirs was last logged (a drag sends ten a second)
local MOVE_LOG_MS = 10000

SecureEvent('whip_core:server:ovMovePlayer', {
    permission = LIVE,
    whileDead = true,
    rateLimit = 50,
    burst = 20,
    params = { { 'sid', 'id' }, { 'x', 'number', -20000, 20000 }, { 'y', 'number', -20000, 20000 },
               { 'z', 'number', -500, 3000 }, { 'heading', 'number', -720, 720 } },
}, function(source, _, sid, x, y, z, heading)
    if not Players[sid] then return false, 'They are not loaded in' end
    local ped = GetPlayerPed(sid)
    if not ped or ped == 0 then return false, 'They are not in the world' end
    SetEntityCoords(ped, x, y, z, false, false, false, false)
    SetEntityHeading(ped, heading % 360.0)
    local key, now = source .. ':' .. sid, GetGameTimer()
    if DirectorLive and now - (movedSaid[key] or -MOVE_LOG_MS) >= MOVE_LOG_MS then
        movedSaid[key] = now
        local what, charId = logName(ped, sid)
        DirectorLive.log(source, 'moved ' .. what, { x = x, y = y, z = z }, charId)
    end
end)
AddEventHandler('playerDropped', function()
    local src = source
    for key in pairs(movedSaid) do
        local a, b = key:match('^(%d+):(%d+)$')
        if tonumber(a) == src or tonumber(b) == src then movedSaid[key] = nil end
    end
end)
