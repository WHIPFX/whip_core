-- ============================================
-- Systems — cards about the world: cars, garages, doors, areas
-- ============================================
--
-- Cards about things in the world, over whip_core's internal functions, with
-- cards_server.lua's rules. Whip's live records (Vehicles.getDef, Doors.getDef, Garages.get) are read
-- here and never handed out: a card answers plain values. What a card changes is the system's own (a
-- temporary car it made, under its tag) or this pulse's player's (their own car's lock, garage), so it
-- has no power, except a car's stats (fuel, nitrous: value), which are "others".

local C = SystemCards

local function define(def)
    def.side = 'server'
    local ok, why = C.define(def)
    if not ok then print('^1[whip_core:systems] card type refused: ' .. tostring(why) .. '^0') end
end

local function placeOf(c) return c and { x = c.x, y = c.y, z = c.z } or nil end

-- ============================================
-- Triggers
-- ============================================

define({
    type = 'when.engine', category = 'when', kind = 'trigger', title = 'When an Engine Starts or Stops',
    desc = 'A car\'s engine starts or stops (the server\'s own record: a driver with the key in the ignition). Driver is who is at the wheel, if anyone.',
    props = { { key = 'when', kind = 'select', label = 'When it', options = { 'starts', 'stops', 'either' }, default = 'starts' } },
    trigger = { name = 'car.engine', match = function(ctx, p)
        if type(p) ~= 'table' or not p.vehicle then return nil end
        local want = ctx:prop('when')
        if (want == 'starts' and not p.on) or (want == 'stops' and p.on) then return nil end
        return { car = p.vehicle, driver = p.player, running = p.on == true }, { player = p.player, vehicle = p.vehicle }
    end },
    values = { outputs = { { key = 'car', type = 'vehicle', label = 'Car' }, { key = 'driver', type = 'player', label = 'Driver' },
                           { key = 'running', type = 'bool', label = 'Running' } } },
})

-- ============================================
-- Cars
-- ============================================

define({
    type = 'car.info', category = 'cars', kind = 'value', title = 'Car Details', api = 'GetVehicle',
    desc = 'What whip knows about a car: its plate and model, whose it is, locked or not, and where it is kept. Out says if it is in the world now.',
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } },
               outputs = { { key = 'found', type = 'bool', label = 'Found' }, { key = 'plate', type = 'text', label = 'Plate' },
                           { key = 'model', type = 'text', label = 'Model' }, { key = 'owner', type = 'character', label = 'Owner' },
                           { key = 'locked', type = 'bool', label = 'Locked' }, { key = 'out', type = 'bool', label = 'Out' },
                           { key = 'garage', type = 'text', label = 'Garage' }, { key = 'temporary', type = 'bool', label = 'Temporary' } } },
    value = function(ctx)
        local id = ctx:need('car')
        local def = Vehicles.getDef(id)
        if not def then return { found = false, plate = '', model = '', locked = false, out = false, garage = '', temporary = false } end
        return { found = true, plate = tostring(def.plate or ''), model = tostring(def.model or ''), owner = def.ownerCharId,
                 locked = def.locked ~= false, out = Vehicles.getEntity(id) ~= nil, garage = tostring(def.garage or ''),
                 temporary = def.temp ~= nil }
    end,
})

define({
    type = 'car.where', category = 'cars', kind = 'value', title = 'Where the Car Is', api = 'GetVehiclePosition',
    desc = 'Where a car is: where it is now if it is out in the world (Out), else where it was left.',
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } },
               outputs = { { key = 'place', type = 'vector', label = 'Place' }, { key = 'out', type = 'bool', label = 'Out' } } },
    value = function(ctx)
        local id = ctx:need('car')
        local ent = Vehicles.getEntity(id)
        if ent and DoesEntityExist(ent) then return { place = placeOf(GetEntityCoords(ent)), out = true } end
        local def = Vehicles.getDef(id)
        if def and def.x and def.y and def.z then return { place = { x = def.x, y = def.y, z = def.z }, out = false } end
        return { out = false }
    end,
})

define({
    type = 'car.stat', category = 'cars', kind = 'value', title = 'Car Stat', api = { 'GetVehicleStat', 'HasVehicleStat' },
    desc = 'One of a car\'s stats: fuel, engine (1 running, 0 off), or one a resource added. Known is no for a stat this server does not have.',
    props = { { key = 'stat', kind = 'text', label = 'Stat', required = true, default = 'fuel', maxLength = 40 } },
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } },
               outputs = { { key = 'value', type = 'number', label = 'Value' }, { key = 'known', type = 'bool', label = 'Known' } } },
    value = function(ctx)
        local name = ctx:prop('stat')
        if not VehicleStats.isRegistered(name) then return { value = 0, known = false } end
        return { value = tonumber(VehicleStats.get(ctx:need('car'), name)) or 0, known = true }
    end,
})

define({
    type = 'car.isDriving', category = 'cars', kind = 'value', title = 'Is Driving?', api = { 'IsPlayerDrivingVehicle', 'IsPlayerInVehicle' },
    desc = 'Yes or no: is a player driving this car (or, with Any Seat, in it at all), as the server sees the seats.',
    props = { { key = 'seat', kind = 'select', label = 'Seat', options = { 'driver', 'any seat' }, default = 'driver' } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'car', type = 'vehicle', label = 'Car' } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' } } },
    value = function(ctx)
        local src = ctx:source(ctx:need('player'))
        if not src then return { result = false } end
        local id = ctx:need('car')
        local yes = ctx:prop('seat') == 'any seat' and Vehicles.isPlayerIn(src, id) or Vehicles.isPlayerDriving(src, id)
        return { result = yes == true }
    end,
})

define({
    type = 'car.hasKey', category = 'cars', kind = 'value', title = 'Has Car Key?', api = 'HasVehicleKey',
    desc = 'Yes or no: does a player carry a key that fits this car.',
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'car', type = 'vehicle', label = 'Car' } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' } } },
    value = function(ctx)
        local src = ctx:source(ctx:need('player'))
        local p = src and Players[src]
        return { result = p ~= nil and Vehicles.playerHasKey(p, ctx:need('car')) == true }
    end,
})

define({
    type = 'car.byPlate', category = 'cars', kind = 'value', title = 'Car With Plate', api = 'GetVehicle',
    desc = 'The car with this plate, if whip knows one.',
    values = { inputs = { { key = 'plate', type = 'text', label = 'Plate' } },
               outputs = { { key = 'car', type = 'vehicle', label = 'Car' }, { key = 'found', type = 'bool', label = 'Found' } } },
    value = function(ctx)
        local plate = ctx:need('plate')
        local id = plate:match('%S') and (Vehicles.getByPlate(plate)) or nil
        return { car = id, found = id ~= nil }
    end,
})

-- ============================================
-- Cars a system makes, locks and marks
-- ============================================

local CORE = 'whip_core'
local CALL_TIMEOUT_S = 15
--- At most this many temporary cars per system at once (server load).
local MAX_CARS = 16
--- [tag] = cars asked for and not yet made (the activation is still waiting on them).
local making = {}

--- Is this a temporary car THIS system made (this switch-on, or this Test)?
local function ownTemp(ctx, id)
    local def = Vehicles.getDef(id)
    return def ~= nil and def.temp == CORE and def.tempTag == ctx:tag()
end

local KEY_TO = { 'their pocket', 'in the ignition', 'nobody' }

define({
    type = 'car.spawnTemp', category = 'cars', kind = 'wait', title = 'Spawn Temporary Car', api = 'SpawnTempVehicle', makes = 'vehicle',
    desc = 'Makes a car that is not anyone\'s to keep (a rental, a test drive): at a place, its key in a player\'s pocket, in the ignition, or nowhere. It goes when the system is switched off, after its minutes, or when left alone.',
    props = { { key = 'model', kind = 'text', label = 'Model', required = true, default = 'faggio', maxLength = 60 },
              { key = 'key', kind = 'select', label = 'The key', options = KEY_TO, default = 'their pocket' },
              { key = 'locked', kind = 'bool', label = 'Locked', default = true },
              { key = 'secure', kind = 'bool', label = 'Cannot be lockpicked', default = true },
              { key = 'minutes', kind = 'number', label = 'Gone after (minutes, 0: no)', default = 0, min = 0, max = 1440 },
              { key = 'idle', kind = 'bool', label = 'Gone when left alone', default = true } },
    outputs = { 'made', 'failed', 'timeout' },
    labels = { made = 'Made', failed = 'Could not', timeout = 'Took too long' },
    values = { inputs = { { key = 'place', type = 'vector', label = 'Place' }, { key = 'heading', type = 'number', label = 'Facing (degrees)', default = 0 },
                          { key = 'player', type = 'player', label = 'Key to (their pocket)', optional = true } },
               outputs = { { key = 'car', type = 'vehicle', label = 'Car' } } },
    run = function(ctx)
        local at, heading = ctx:need('place'), ctx:need('heading')
        local keyTo = ctx:prop('key')
        local who, src = ctx:input('player'), nil
        if keyTo == 'their pocket' then
            src = who and ctx:source(who)
            if not src then ctx:log('the key goes in a player\'s pocket: wire the player in') return 'failed' end
        end
        local tag = ctx:tag()
        -- The car is made on the call's own thread, a tick later: one still being made counts too (a For
        -- Each would otherwise see none yet on every turn).
        if C.liveUnder(tag, 'tempVehicle') + (making[tag] or 0) >= MAX_CARS then
            ctx:log('this system has %d cars out already, the most it may', MAX_CARS)
            return 'failed'
        end
        making[tag] = (making[tag] or 0) + 1
        ctx:onEnd(function()
            local n = (making[tag] or 1) - 1
            making[tag] = n > 0 and n or nil
        end)
        local minutes = tonumber(ctx:prop('minutes')) or 0
        local opts = { locked = ctx:prop('locked') ~= false and keyTo ~= 'in the ignition', secure = ctx:prop('secure') ~= false,
                       keyInIgnition = keyTo == 'in the ignition' or nil, forSource = src, giveKey = src ~= nil,
                       despawnAfter = minutes > 0 and math.floor(minutes * 60) or nil, idleDespawn = ctx:prop('idle') ~= false, tag = tag }
        local model = ctx:prop('model')
        ctx:call(function()
            if who and not ctx:source(who) then return 'failed' end
            local id, err = Vehicles.spawnTempFor(model, vector4(at.x, at.y, at.z, heading), opts, CORE)
            if not id then ctx:log('the car could not be made: %s', tostring(err)) return 'failed' end
            return 'made', { car = id }
        end, {
            -- Made after the card gave up waiting: take it away again.
            late = function(pin, outs) if pin == 'made' and type(outs) == 'table' and outs.car then Vehicles.despawnByRef(outs.car) end end,
        })
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
})

define({
    type = 'car.removeTemp', category = 'cars', kind = 'wait', title = 'Remove Temporary Car', api = 'DespawnVehicle',
    desc = 'Takes away a temporary car THIS system made (its key too). Any other car is Not Ours.',
    outputs = { 'removed', 'notOurs', 'timeout' },
    labels = { removed = 'Removed', notOurs = 'Not ours', timeout = 'Took too long' },
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } } },
    run = function(ctx)
        local id = ctx:need('car')
        if not ownTemp(ctx, id) then return 'notOurs' end
        ctx:call(function()
            local ok, why = Vehicles.despawnByRef(id)
            if not ok then ctx:log('the car could not be removed: %s', tostring(why)) end
            return 'removed'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
})

define({
    type = 'car.lock', category = 'cars', kind = 'wait', title = 'Lock / Unlock Car', api = 'SetVehicleLocked',
    desc = 'Locks or unlocks a car: one THIS system made, or this pulse\'s player\'s own. Anyone else\'s is Refused.',
    props = { { key = 'action', kind = 'select', label = 'Do', options = { 'lock', 'unlock' }, default = 'lock' } },
    outputs = { 'done', 'refused', 'timeout' },
    labels = { done = 'Done', refused = 'Refused', timeout = 'Took too long' },
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } } },
    run = function(ctx)
        local id = ctx:need('car')
        local def = Vehicles.getDef(id)
        if not def then return 'refused' end
        local mine = false
        if not ownTemp(ctx, id) then
            local src = ctx:source(ctx:player())
            local p = src and Players[src]
            mine = p ~= nil and p.charId ~= nil and def.ownerCharId == p.charId
            if not mine then ctx:log('car %s is neither this system\'s nor this pulse\'s player\'s', tostring(id)) return 'refused' end
        end
        local lock = ctx:prop('action') ~= 'unlock'
        ctx:call(function()
            local ok, why = Vehicles.setLocked(id, lock)
            if not ok then ctx:log('it could not be %s: %s', lock and 'locked' or 'unlocked', tostring(why)) return 'refused' end
            return 'done'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
})

define({
    type = 'car.readData', category = 'cars', kind = 'value', title = 'Read Car Data', api = 'GetVehicleData',
    desc = 'A value a resource keeps on a car under a name (whip_autos\' tuning, a job\'s mark). Set says if it is there.',
    props = { { key = 'key', kind = 'text', label = 'Name', required = true, maxLength = 40 } },
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } },
               outputs = { { key = 'value', type = 'any', label = 'Value' }, { key = 'set', type = 'bool', label = 'Set' } } },
    value = function(ctx)
        local v = VehicleData.get(ctx:need('car'), ctx:prop('key'))
        return { value = v, set = v ~= nil }
    end,
})

--- Is this car this pulse's player's own (their character owns it)?
local function playersOwn(ctx, id)
    local def = Vehicles.getDef(id)
    local src = def and ctx:source(ctx:player())
    local p = src and Players[src]
    return def ~= nil and p ~= nil and p.charId ~= nil and def.ownerCharId == p.charId, src, p
end

define({
    type = 'car.owned', category = 'cars', kind = 'value', title = 'Their Cars', api = 'GetVehiclesOf',
    desc = 'The cars a player\'s character owns (64 at most), wherever they are kept.',
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'cars', type = 'list', label = 'Cars' }, { key = 'count', type = 'number', label = 'How many' } } },
    value = function(ctx)
        local src = ctx:source(ctx:need('player'))
        local p = src and Players[src]
        if not p or not p.charId then return { cars = {}, count = 0 } end
        local ids = Vehicles.ownedIds(p.charId)
        local list = {}
        for i = 1, math.min(#ids, C.MAX_LIST) do list[i] = ids[i] end
        return { cars = list, count = #ids }
    end,
})

define({
    type = 'car.store', category = 'cars', kind = 'wait', title = 'Put Car Away', api = 'StoreVehicle',
    desc = 'Puts THIS pulse\'s player\'s own car in a garage (its key; empty: the car\'s own garage). Nobody may be in it.',
    props = { { key = 'garage', kind = 'text', label = 'Garage (empty: its own)', maxLength = 64 } },
    outputs = { 'done', 'refused', 'timeout' },
    labels = { done = 'Put away', refused = 'Refused', timeout = 'Took too long' },
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } },
               outputs = { { key = 'why', type = 'text', label = 'Why not' } } },
    run = function(ctx)
        local id = ctx:need('car')
        local own, _, p = playersOwn(ctx, id)
        if not own or not p then return 'refused', { why = 'not this pulse\'s player\'s car' } end
        local g = ctx:prop('garage')
        if g == '' then g = nil end
        -- Store does not ask whether they may use a garage named (a home's): asked here, as Take Car
        -- Out does (a car filed in a garage its owner cannot open would be stuck there).
        if g and not Garages.canUse(g, p.charId) then return 'refused', { why = 'they may not use that garage' } end
        ctx:call(function()
            local ok, why = Vehicles.store(id, g)
            if not ok then return 'refused', { why = tostring(why) } end
            return 'done'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
})

define({
    type = 'car.retrieve', category = 'cars', kind = 'wait', title = 'Take Car Out', api = 'RetrieveVehicle',
    desc = 'Takes THIS pulse\'s player\'s own car out of the garage it is in (a garage they may use). Then it is out, ready to be put in the world.',
    outputs = { 'done', 'refused', 'timeout' },
    labels = { done = 'Taken out', refused = 'Refused', timeout = 'Took too long' },
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } },
               outputs = { { key = 'why', type = 'text', label = 'Why not' } } },
    run = function(ctx)
        local id = ctx:need('car')
        local own, _, p = playersOwn(ctx, id)
        if not own or not p then return 'refused', { why = 'not this pulse\'s player\'s car' } end
        local def = Vehicles.getDef(id) --[[@as table]]   -- playersOwn has just found it
        local g = def.garage
        -- Retrieve does not ask whether they may use the garage (a home's): asked here.
        if g and g ~= '' and not Garages.canUse(g, p.charId) then return 'refused', { why = 'they may not use that garage' } end
        ctx:call(function()
            local ok, why = Vehicles.retrieve(id, g)
            if not ok then return 'refused', { why = tostring(why) } end
            return 'done'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
})

--- A car stat a card may change: a registered one, never `engine` (the ignition's: changing it would
--- start a car with no key in it).
local function changeableStat(name)
    if name == 'engine' then return nil, 'the engine is the ignition\'s (a key in it, a driver)' end
    if not VehicleStats.isRegistered(name) then return nil, ('this server has no car stat "%s"'):format(tostring(name)) end
    return name
end

-- A car's stats are value: a full tank is what a pump charges for, a nitrous bottle is
-- bought and fitted (whip_autos). So changing one is the power "others", approved by an admin, with a
-- dry run in a Test; on any car whip looks after.
local function carStat(cardType, title, desc, add)
    define({
        type = cardType, category = 'cars', kind = 'action', title = title, api = add and 'AddVehicleStat' or 'SetVehicleStat',
        power = 'others',
        desc = desc,
        props = { { key = 'stat', kind = 'text', label = 'Stat', required = true, default = 'fuel', maxLength = 40 } },
        outputs = { 'out', 'refused' },
        labels = { refused = 'Refused' },
        values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' }, { key = 'value', type = 'number', label = add and 'Add (minus to take)' or 'To' } } },
        dryRun = function(ctx)
            local id = ctx:need('car')
            local name, why = changeableStat(ctx:prop('stat'))
            if not name or not Vehicles.getDef(id) then ctx:log('%s', tostring(why or 'no such car')) return 'refused' end
            ctx:log('test: car %s\'s %s %s %s (nothing really changed)', tostring(id), name, add and 'changed by' or 'set to', tostring(ctx:need('value')))
            return 'out'
        end,
        run = function(ctx)
            local id = ctx:need('car')
            if not Vehicles.getDef(id) then ctx:log('car %s is not one whip looks after', tostring(id)) return 'refused' end
            local name, why = changeableStat(ctx:prop('stat'))
            if not name then ctx:log('%s', why) return 'refused' end
            local m = ctx:meta()
            local label = ('system %s'):format(tostring(m.shortId or '?'))
            local ok, swhy
            if add then ok, swhy = VehicleStats.add(id, name, ctx:need('value'), label)
            else ok, swhy = VehicleStats.set(id, name, ctx:need('value'), label) end
            if not ok then ctx:log('%s: %s', name, tostring(swhy)) return 'refused' end
            return 'out'
        end,
    })
end
carStat('car.setStat', 'Set Car Stat', 'Sets one of a car\'s stats (fuel, a resource\'s), held to its own range. Not the engine (the ignition\'s). A systems admin approves it.', false)
carStat('car.addStat', 'Add to Car Stat', 'Adds to (or, with a minus, takes from) one of a car\'s stats: a fuel pump, a repair. A systems admin approves it.', true)

-- No "Write Car Data": Vehicle Data is an 8 KB statebag sent to everyone
-- in range, shared with whip_autos and others, and saved at once: wrong for a system's state. A
-- system keeps what it remembers about a car in its own per-car variables (sysvar). Reading another
-- resource's data on a car is fine (Read Car Data, above).

-- ============================================
-- Garages
-- ============================================

define({
    type = 'garage.nearest', category = 'world', kind = 'value', title = 'Nearest Garage', api = 'GetNearestGarage',
    desc = 'The public garage nearest a place (its key), within a distance. Somebody\'s own garage is never named.',
    values = { inputs = { { key = 'place', type = 'vector', label = 'Place' }, { key = 'range', type = 'number', label = 'Within (m)', default = 100 } },
               outputs = { { key = 'garage', type = 'text', label = 'Garage' }, { key = 'distance', type = 'number', label = 'Distance (m)' },
                           { key = 'found', type = 'bool', label = 'Found' } } },
    value = function(ctx)
        local at = ctx:need('place')
        local key, d = Garages.nearest(at.x, at.y, at.z, math.max(1, ctx:need('range')))
        if not key then return { garage = '', distance = 0, found = false } end
        return { garage = tostring(key), distance = tonumber(d) or 0, found = true }
    end,
})

define({
    type = 'garage.canUse', category = 'world', kind = 'value', title = 'May Use Garage?', api = 'CanUseGarage',
    desc = 'Yes or no: may a player use this garage (its key). A public one, anyone; a home\'s, only those with access.',
    props = { { key = 'garage', kind = 'text', label = 'Garage', required = true, maxLength = 64 } },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' }, { key = 'why', type = 'text', label = 'Why not' } } },
    value = function(ctx)
        local key = ctx:prop('garage')
        if not Garages.get(key) then return { result = false, why = 'No such garage' } end
        local src = ctx:source(ctx:need('player'))
        local p = src and Players[src]
        if not p or not p.charId then return { result = false, why = 'not here' } end
        if Garages.canUse(key, p.charId) then return { result = true, why = '' } end
        local owner = Garages.ownerLabel(key)
        return { result = false, why = owner and ('That garage belongs to ' .. tostring(owner)) or 'That garage is private' }
    end,
})

-- ============================================
-- Doors
-- ============================================

define({
    type = 'door.at', category = 'world', kind = 'value', title = 'Door Here', api = 'GetDoorByPosition',
    desc = 'The whip door at a place (within a little distance), and whether it is locked.',
    values = { inputs = { { key = 'place', type = 'vector', label = 'Place' }, { key = 'range', type = 'number', label = 'Within (m)', default = 1.5 } },
               outputs = { { key = 'door', type = 'door', label = 'Door' }, { key = 'found', type = 'bool', label = 'Found' },
                           { key = 'locked', type = 'bool', label = 'Locked' } } },
    value = function(ctx)
        local at = ctx:need('place')
        local d = Doors.getByPosition(at.x, at.y, at.z, math.max(0.1, math.min(10, ctx:need('range'))))
        if not d then return { found = false, locked = false } end
        return { door = d.doorId, found = true, locked = d.locked == true }
    end,
})

define({
    type = 'door.isLocked', category = 'world', kind = 'value', title = 'Is Door Locked?', api = { 'IsDoorLocked', 'GetDoor' },
    desc = 'Yes or no: is a whip door locked now. Found is no for a door that is not there.',
    values = { inputs = { { key = 'door', type = 'door', label = 'Door' } },
               outputs = { { key = 'locked', type = 'bool', label = 'Locked' }, { key = 'found', type = 'bool', label = 'Found' } } },
    value = function(ctx)
        local d = Doors.getDef(ctx:need('door'))
        return { locked = d ~= nil and d.locked == true, found = d ~= nil }
    end,
})

define({
    type = 'door.mayOpen', category = 'world', kind = 'value', title = 'May Open Door?', api = 'IsAuthorizedForDoor',
    desc = 'Yes or no: may a player open this door (its job, key or item rules), and if not, why.',
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'door', type = 'door', label = 'Door' } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' }, { key = 'why', type = 'text', label = 'Why not' } } },
    value = function(ctx)
        local d = Doors.getDef(ctx:need('door'))
        if not d then return { result = false, why = 'Door not found' } end
        local src = ctx:source(ctx:need('player'))
        local p = src and Players[src]
        if not p then return { result = false, why = 'not here' } end
        local ok, why = Doors.isAuthorizedWithReason(src, p, d)
        return { result = ok == true, why = ok and '' or tostring(why or 'Not allowed') }
    end,
})

-- ============================================
-- Areas (whip's zones, by key)
-- ============================================

--- A zone the server itself knows (saved, or made on the server), never one only players' games
--- reported: its shape is whatever they said (zones.lua's containsTrusted).
local function trustedZone(key)
    local z = type(key) == 'string' and key ~= '' and Zones.resolve(key) or nil
    if not z or z._reporters ~= nil then return nil end
    return z
end

define({
    type = 'area.has', category = 'world', kind = 'value', title = 'Is It in the Area?', api = 'ZoneContains',
    desc = 'Yes or no: is a place inside a zone (its key). Only zones the server keeps count.',
    props = { { key = 'area', kind = 'text', label = 'Zone key', required = true, maxLength = 64 } },
    values = { inputs = { { key = 'place', type = 'vector', label = 'Place' } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' } } },
    value = function(ctx)
        return { result = Zones.containsTrusted(ctx:prop('area'), ctx:need('place')) == true }
    end,
})

define({
    type = 'area.players', category = 'world', kind = 'value', title = 'Players in Area', api = 'GetPlayersInZone',
    desc = 'The players inside a zone (its key) now, 64 at most. Only zones the server keeps count.',
    props = { { key = 'area', kind = 'text', label = 'Zone key', required = true, maxLength = 64 } },
    values = { outputs = { { key = 'players', type = 'list', label = 'Players' }, { key = 'count', type = 'number', label = 'How many' } } },
    value = function(ctx)
        local key = ctx:prop('area')
        if not trustedZone(key) then return { players = {}, count = 0 } end
        local list, n = C.playerList(ctx, Zones.getPlayersInZone(key))
        return { players = list, count = n }
    end,
})
