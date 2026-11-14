-- ============================================
-- Systems — cards that act on others, or on the whole server
-- ============================================
--
-- The third power, "others": car and house keys, hiring and roles, time and weather, a player's
-- stats, any whip door, any car, a shop's prices, searching someone's pockets. (Drop Item, here with
-- the ground, is "items": an item from nothing.) A revision with one of these switches on only after a systems admin
-- ticks "others" for it (hub.lua), and each runs its `dryRun` in an editor's Test: it says what it
-- would have done, and nothing changes. (Drop Item's Test pile is real: stamped, only the tester can
-- pick it up, removed when the test ends; server/systems/test_items.lua.) The rest of cards_server.lua's rules hold: a player only
-- through ctx:source, anything that waits in ctx:call, whip_core's internal functions, never exports.

local C = SystemCards
local CORE = 'whip_core'
local CALL_TIMEOUT_S = 15

--- Every card here has the power "others", unless it says `power = false` (a read, or giving back
--- what the system itself took).
local function define(def)
    def.side = 'server'
    if def.power == nil then def.power = 'others' elseif def.power == false then def.power = nil end
    local ok, why = C.define(def)
    if not ok then print('^1[whip_core:systems] card type refused: ' .. tostring(why) .. '^0') end
end

--- What a Test says it would have done (cards_server.lua's `tested`), in the log and on the
--- tester's screen.
local function tested(ctx, fmt, ...)
    local text = fmt:format(...)
    ctx:log('test: %s (nothing really changed)', text)
    local src = ctx:tester()
    if src then NotifyPlayer(src, ('Test: %s (nothing really changed)'):format(text), 'info') end
end

--- The wired-in player: their value, server id and live record, or nil.
local function playerIn(ctx, key)
    local who = ctx:input(key or 'player')
    local src = who and ctx:source(who)
    local p = src and Players[src]
    if not p or not p.charId then return nil end
    return who, src, p
end

--- The system's words for a change it made (the stats log, a job's history).
local function label(ctx)
    local m = ctx:meta()
    return ('system %s r%s'):format(tostring(m.shortId or '?'), tostring(m.rev or '?'))
end

--- A job prop's job, or nil and why.
local function jobOf(ctx)
    local ref = ctx:prop('job')
    local job = type(ref) == 'string' and ref ~= '' and Jobs.resolve(tonumber(ref) or ref) or nil
    if not job then return nil, ('there is no job "%s"'):format(tostring(ref)) end
    return job
end

-- ============================================
-- Car keys
-- ============================================

define({
    type = 'car.giveKey', category = 'cars', kind = 'wait', title = 'Give Car Key', api = 'GiveVehicleKey',
    desc = 'Puts a key to this car in a player\'s pockets (a sale, a valet). They may already have one: that is Refused.',
    outputs = { 'given', 'refused', 'timeout' },
    labels = { given = 'Given', refused = 'Refused', timeout = 'Took too long' },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'car', type = 'vehicle', label = 'Car' } } },
    run = function(ctx)
        local _, src = playerIn(ctx)
        if not src then return 'refused' end
        local id = ctx:need('car')
        ctx:call(function()
            local _, s2, p = playerIn(ctx)
            if not p or s2 ~= src then return 'refused' end
            local ok, why = Vehicles.giveKey(src, p, id)
            if not ok then ctx:log('no key given: %s', tostring(why)) return 'refused' end
            return 'given'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    dryRun = function(ctx)
        local _, _, p = playerIn(ctx)
        if not p then return 'refused' end
        tested(ctx, '%s given a key to car %s', tostring(p.fullName), tostring(ctx:need('car')))
        return 'given'
    end,
})

define({
    type = 'car.takeKey', category = 'cars', kind = 'wait', title = 'Take Car Key', api = 'RemoveVehicleKey',
    desc = 'Takes every key to this car out of a player\'s pockets (a repossession). No Key if they had none.',
    outputs = { 'taken', 'noKey', 'timeout' },
    labels = { taken = 'Taken', noKey = 'No key', timeout = 'Took too long' },
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'car', type = 'vehicle', label = 'Car' } } },
    run = function(ctx)
        local _, src = playerIn(ctx)
        if not src then return 'noKey' end
        local id = ctx:need('car')
        ctx:call(function()
            local _, s2, p = playerIn(ctx)
            if not p or s2 ~= src then return 'noKey' end
            return Vehicles.removeKey(src, p, id) and 'taken' or 'noKey'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    dryRun = function(ctx)
        local _, _, p = playerIn(ctx)
        local id = ctx:need('car')
        if not p or not Vehicles.playerHasKey(p, id) then return 'noKey' end
        tested(ctx, 'every key to car %s taken from %s', tostring(id), tostring(p.fullName))
        return 'taken'
    end,
})

-- ============================================
-- Any car
-- ============================================

define({
    type = 'car.lockAny', category = 'cars', kind = 'wait', title = 'Lock / Unlock Any Car', api = 'SetVehicleLocked',
    desc = 'Locks or unlocks any car whip looks after, whoever\'s it is (a police lockdown, a valet). Lock / Unlock Car does a system\'s own without this.',
    props = { { key = 'action', kind = 'select', label = 'Do', options = { 'lock', 'unlock' }, default = 'lock' } },
    outputs = { 'done', 'refused', 'timeout' },
    labels = { done = 'Done', refused = 'Refused', timeout = 'Took too long' },
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } } },
    run = function(ctx)
        local id = ctx:need('car')
        if not Vehicles.getDef(id) then return 'refused' end
        local lock = ctx:prop('action') ~= 'unlock'
        ctx:call(function()
            local ok, why = Vehicles.setLocked(id, lock)
            if not ok then ctx:log('car %s: %s', tostring(id), tostring(why)) return 'refused' end
            return 'done'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    dryRun = function(ctx)
        local id = ctx:need('car')
        if not Vehicles.getDef(id) then return 'refused' end
        tested(ctx, 'car %s %s', tostring(id), ctx:prop('action') ~= 'unlock' and 'locked' or 'unlocked')
        return 'done'
    end,
})

define({
    type = 'car.removeAny', category = 'cars', kind = 'wait', title = 'Take Any Car Away', api = 'DespawnVehicle',
    desc = 'Takes a car out of the world, whoever\'s it is. Someone\'s own car goes into its garage (it is not deleted); a street car is forgotten. Remove Temporary Car does a system\'s own without this.',
    outputs = { 'removed', 'refused', 'timeout' },
    labels = { removed = 'Removed', refused = 'Refused', timeout = 'Took too long' },
    values = { inputs = { { key = 'car', type = 'vehicle', label = 'Car' } } },
    run = function(ctx)
        local id = ctx:need('car')
        if not Vehicles.getDef(id) then return 'refused' end
        ctx:call(function()
            -- (Whip's one way to take a car away: a street car is deleted, not handed back to GTA where it stands.)
            local ok, why = Vehicles.removeFromWorld(id)
            if not ok then ctx:log('car %s: %s', tostring(id), tostring(why)) return 'refused' end
            return 'removed'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    dryRun = function(ctx)
        local id = ctx:need('car')
        if not Vehicles.getDef(id) then return 'refused' end
        tested(ctx, 'car %s taken out of the world', tostring(id))
        return 'removed'
    end,
})

-- ============================================
-- Any door (held by the system, under its tag)
-- ============================================

local DOOR_WHO = { 'nobody (only the cards)', 'anyone' }

define({
    type = 'door.set', category = 'world', kind = 'action', title = 'Lock / Unlock Door', api = { 'HoldDoor', 'SetDoorLocked', 'SetHeldDoorAccess' },
    desc = 'Takes charge of a whip door (wire in Door Here) and locks or unlocks it, and says who may press it meanwhile. It goes back to its own rules when the system is switched off, or with Give Door Back.',
    props = { { key = 'action', kind = 'select', label = 'Do', options = { 'unlock', 'lock' }, default = 'lock' },
              { key = 'who', kind = 'select', label = 'Who may press it', options = DOOR_WHO, default = DOOR_WHO[1] } },
    outputs = { 'out', 'failed' },
    labels = { out = 'Done', failed = 'Could not' },
    values = { inputs = { { key = 'door', type = 'door', label = 'Door' } } },
    run = function(ctx)
        local d = Doors.getDef(ctx:need('door'))
        if not d then return 'failed' end
        local h = Doors.holdOf(d.doorId)
        if not (h and h.owner == CORE and h.tag == ctx:tag()) then
            local id, how = Doors.hold(CORE, { model = d.model, x = d.x, y = d.y, z = d.z, heading = d.heading, label = d.label }, { tag = ctx:tag() })
            if not id then ctx:log('door %s: %s', tostring(d.doorId), tostring(how)) return 'failed' end
        end
        local ok, why = Doors.setLocked(d.doorId, ctx:prop('action') == 'lock', { cause = 'system' })
        if not ok then ctx:log('door %s: %s', tostring(d.doorId), tostring(why)) return 'failed' end
        Doors.setHoldAccess(CORE, d.doorId, ctx:prop('who') == 'anyone' and {} or nil)
        return 'out'
    end,
    dryRun = function(ctx)
        local d = Doors.getDef(ctx:need('door'))
        if not d then return 'failed' end
        tested(ctx, 'door %s %s, pressed by %s', tostring(d.doorId), ctx:prop('action') == 'lock' and 'locked' or 'unlocked', tostring(ctx:prop('who')))
        return 'out'
    end,
})

define({
    type = 'door.release', category = 'world', kind = 'action', title = 'Give Door Back', api = 'ReleaseDoor',
    power = false,
    desc = 'Hands a door this system took charge of back to its own rules (as it was). A door it does not hold is left alone.',
    values = { inputs = { { key = 'door', type = 'door', label = 'Door' } } },
    run = function(ctx)
        local id = ctx:need('door')
        local h = Doors.holdOf(id)
        if h and h.owner == CORE and h.tag == ctx:tag() then Doors.releaseHold(CORE, id) end
        return 'out'
    end,
})

-- ============================================
-- Houses
-- ============================================

define({
    type = 'home.at', category = 'world', kind = 'value', title = 'Property Here', api = 'GetPropertyAt',
    power = false,
    desc = 'The property (a house, an apartment, a business) whose space holds a place, if any.',
    values = { inputs = { { key = 'place', type = 'vector', label = 'Place' } },
               outputs = { { key = 'property', type = 'number', label = 'Property' }, { key = 'found', type = 'bool', label = 'Found' },
                           { key = 'name', type = 'text', label = 'Name' } } },
    value = function(ctx)
        local at = ctx:need('place')
        local rec = Properties.at(at.x, at.y, at.z, 0.5)
        if not rec then return { found = false, name = '' } end
        return { property = rec.propertyId, found = true, name = tostring(rec.name or '') }
    end,
})

local function homeKey(cardType, title, desc, grant)
    define({
        type = cardType, category = 'world', kind = 'wait', title = title, api = grant and 'GivePropertyKey' or 'RemovePropertyKey',
        desc = desc,
        outputs = { 'done', 'refused', 'timeout' },
        labels = { done = 'Done', refused = 'Refused', timeout = 'Took too long' },
        values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'property', type = 'number', label = 'Property' } },
                   outputs = { { key = 'why', type = 'text', label = 'Why not' } } },
        run = function(ctx)
            local _, _, p = playerIn(ctx)
            if not p then return 'refused', { why = 'not here' } end
            local id, charId = math.floor(ctx:need('property')), p.charId
            ctx:call(function()
                local ok, why
                if grant then ok, why = Properties.grantKey(id, charId) else ok, why = Properties.revokeKey(id, charId) end
                if not ok then return 'refused', { why = tostring(why) } end
                return 'done'
            end)
            ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
            return nil
        end,
        dryRun = function(ctx)
            local _, _, p = playerIn(ctx)
            if not p then return 'refused', { why = 'not here' } end
            local id = math.floor(ctx:need('property'))
            if not Properties.get(id) then return 'refused', { why = 'Unknown property' } end
            tested(ctx, '%s %s a key to property %d', tostring(p.fullName), grant and 'given' or 'had taken back', id)
            return 'done'
        end,
    })
end
homeKey('home.giveKey', 'Give House Key', 'Gives a player a key to a property (wire in Property Here): its doors open for them, as a keyholder\'s do.', true)
homeKey('home.takeKey', 'Take House Key', 'Takes a player\'s key to a property back. Refused if they had none.', false)

-- ============================================
-- Jobs: hiring and roles
-- ============================================

local CHECKED = { 'no (the system decides)', 'by this pulse\'s player\'s rank' }

--- The actor a job change is checked against: nil (the system decides) or this pulse's player's
--- character (their rank and their canHire/canFire/canPromote say yes or no).
local function actorOf(ctx)
    if ctx:prop('checked') ~= CHECKED[2] then return nil end
    local src = ctx:source(ctx:player())
    local p = src and Players[src]
    return p and p.charId or false
end

local function jobChange(cardType, title, desc, needsRole, act, words)
    local props = { { key = 'job', kind = 'text', label = 'Job', required = true, maxLength = 50 } }
    if needsRole ~= nil then
        props[#props + 1] = { key = 'role', kind = 'text', label = needsRole and 'Role' or 'Role (empty: the lowest)', required = needsRole, maxLength = 50 }
    end
    props[#props + 1] = { key = 'checked', kind = 'select', label = 'Checked', options = CHECKED, default = CHECKED[1] }
    define({
        type = cardType, category = 'jobs', kind = 'wait', title = title, api = act.api,
        desc = desc, props = props,
        outputs = { 'done', 'refused', 'timeout' },
        labels = { done = 'Done', refused = 'Refused', timeout = 'Took too long' },
        values = { inputs = { { key = 'player', type = 'player', label = 'Player' } },
                   outputs = { { key = 'why', type = 'text', label = 'Why not' } } },
        run = function(ctx)
            local job, jwhy = jobOf(ctx)
            if not job then return 'refused', { why = jwhy } end
            local _, _, p = playerIn(ctx)
            if not p then return 'refused', { why = 'not here' } end
            local role
            if needsRole ~= nil then
                local ref = ctx:prop('role')
                if ref and ref ~= '' then role = Jobs.resolveRole(job.jobId, tonumber(ref) or ref)
                elseif not needsRole then role = Jobs.lowestRole(job.jobId) end
                if not role then return 'refused', { why = ('%s has no role "%s"'):format(job.key, tostring(ref)) } end
            end
            local actor = actorOf(ctx)
            if actor == false then return 'refused', { why = 'this pulse has no player to check' } end
            local charId = p.charId
            ctx:call(function()
                local ok, why = act.fn(job.jobId, charId, role and role.roleId, actor)
                if not ok then return 'refused', { why = tostring(why) } end
                return 'done'
            end)
            ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
            return nil
        end,
        dryRun = function(ctx)
            local job, jwhy = jobOf(ctx)
            if not job then return 'refused', { why = jwhy } end
            local _, _, p = playerIn(ctx)
            if not p then return 'refused', { why = 'not here' } end
            tested(ctx, '%s %s at %s', tostring(p.fullName), words, tostring(job.name or job.key))
            return 'done'
        end,
    })
end

jobChange('job.hire', 'Hire', 'Takes a player on at a job (its key), at a role or the lowest. Checked by this pulse\'s player\'s rank, they may only hire below their own. A role gives its bank access too.',
    false, { api = 'HirePlayer', fn = function(jobId, charId, roleId, actor) return Jobs.hire(jobId, charId, roleId, actor, actor) end }, 'hired')
jobChange('job.fire', 'Fire', 'Lets a player go from a job (its key): off duty there, and its bank access taken back.',
    nil, { api = 'FirePlayer', fn = function(jobId, charId, _, actor) return Jobs.fire(jobId, charId, actor) end }, 'let go')
jobChange('job.setRole', 'Set Role', 'Moves a player to another role at a job (promote or demote). Checked, nobody gives a role at or above their own.',
    true, { api = 'SetPlayerRole', fn = function(jobId, charId, roleId, actor) return Jobs.setRole(jobId, charId, roleId, actor) end }, 'given a new role')

-- ============================================
-- A player's stats
-- ============================================

local function statChange(cardType, title, desc, add)
    define({
        type = cardType, category = 'players', kind = 'action', title = title, api = add and 'AddStat' or 'SetStat',
        desc = desc,
        props = { { key = 'stat', kind = 'text', label = 'Stat', required = true, default = 'hunger', maxLength = 40 } },
        outputs = { 'out', 'refused' },
        labels = { refused = 'Refused' },
        values = { inputs = { { key = 'player', type = 'player', label = 'Player' },
                              { key = 'value', type = 'number', label = add and 'Add (minus to take)' or 'To' } } },
        run = function(ctx)
            local _, src = playerIn(ctx)
            if not src then return 'refused' end
            local name, v = ctx:prop('stat'), ctx:need('value')
            local ok, why
            if add then ok, why = Stats.add(src, name, v, label(ctx)) else ok, why = Stats.set(src, name, v, label(ctx)) end
            if not ok then ctx:log('%s: %s', tostring(name), tostring(why)) return 'refused' end
            return 'out'
        end,
        dryRun = function(ctx)
            local _, _, p = playerIn(ctx)
            if not p then return 'refused' end
            tested(ctx, '%s\'s %s %s %s', tostring(p.fullName), tostring(ctx:prop('stat')), add and 'changed by' or 'set to', tostring(ctx:need('value')))
            return 'out'
        end,
    })
end
statChange('stat.set', 'Set Stat', 'Sets one of a player\'s stats (hunger, thirst, health, armour, or a resource\'s), held to its own lowest and highest. Health 0 is down.', false)
statChange('stat.add', 'Add to Stat', 'Adds to (or, with a minus, takes from) one of a player\'s stats, held to its own lowest and highest.', true)

-- ============================================
-- Shops, the ground, someone's pockets
-- ============================================

define({
    type = 'shop.setPrice', category = 'world', kind = 'wait', title = 'Set Shop Price', api = 'SetShopItemPrice',
    desc = 'Sets what a stocked shop (its key) sells an item for, on every shelf that holds it now or later (a sale, a price rise). A shop with a fixed catalogue is set in its own editor.',
    props = { { key = 'shop', kind = 'text', label = 'Shop (its key)', required = true, maxLength = 64 },
              { key = 'item', kind = 'item', label = 'Item', required = true } },
    outputs = { 'done', 'refused', 'timeout' },
    labels = { done = 'Done', refused = 'Refused', timeout = 'Took too long' },
    values = { inputs = { { key = 'price', type = 'number', label = 'Price ($)' }, { key = 'forSale', type = 'bool', label = 'For sale', default = true } } },
    run = function(ctx)
        local ref = ctx:prop('shop')
        local def = Shops.getByKey(ref) or Shops.getDef(tonumber(ref) or -1)
        if not def or def.mode ~= 'stocked' or not def.containerId then
            ctx:log('"%s" is not a stocked shop', tostring(ref))
            return 'refused'
        end
        local item, price = ctx:prop('item'), math.max(0, math.floor(ctx:need('price')))
        local forSale = ctx:input('forSale') ~= false
        local containerId = def.containerId
        -- One price for the item: prices are per item, so it is set once, on the shelves or not (a price
        -- before the first delivery).
        ctx:call(function()
            local ok, why = Shops.setItemPrice(containerId, item, price, forSale)
            if not ok then ctx:log('pricing %s: %s', tostring(item), tostring(why)) return 'refused' end
            return 'done'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    dryRun = function(ctx)
        tested(ctx, '%s in %s priced at $%d', tostring(ctx:prop('item')), tostring(ctx:prop('shop')), math.max(0, math.floor(ctx:need('price'))))
        return 'done'
    end,
})

-- The row is written before the item exists (ground.lua: an INSERT that waits), so the drop runs in
-- ctx:call (never yielding inside the scheduler). Priced as a card that makes a thing.
define({
    type = 'ground.drop', category = 'items', kind = 'wait', title = 'Drop Item', api = 'CreateGroundItem',
    power = 'items', cost = 10,
    desc = 'Puts items on the ground at a place, from nothing (a supply drop, a reward to pick up). Whoever gets there first takes them.',
    props = { { key = 'item', kind = 'item', label = 'Item', required = true } },
    outputs = { 'out', 'failed', 'timeout' },
    labels = { out = 'Dropped', failed = 'Could not', timeout = 'Took too long' },
    values = { inputs = { { key = 'place', type = 'vector', label = 'Place' }, { key = 'amount', type = 'number', label = 'How many', default = 1 } } },
    run = function(ctx)
        local at = ctx:need('place')
        local item, amount = ctx:prop('item'), math.max(1, math.floor(ctx:need('amount')))
        if not (Config.Items and Config.Items[item]) then ctx:log('%s is not an item on this server', tostring(item)) return 'failed' end
        ctx:call(function()
            local row, why = GroundItems.createItem({ item = item, amount = amount, coords = at })
            if not row then ctx:log('nothing dropped: %s', tostring(why)) return 'failed' end
            return 'out'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    -- A Test's: a real pile, stamped with the test (only its tester can pick it up), removed when the
    -- test ends (test_items.lua).
    dryRun = function(ctx)
        local at = ctx:need('place')
        local item, amount = ctx:prop('item'), math.max(1, math.floor(ctx:need('amount')))
        if not (Config.Items and Config.Items[item]) then ctx:log('%s is not an item on this server', tostring(item)) return 'failed' end
        local meta = SystemsTestItems.stamp(ctx:tag(), item)
        ctx:call(function()
            local row, why = GroundItems.createItem({ item = item, amount = amount, coords = at, metadata = meta })
            if not row then ctx:log('nothing dropped: %s', tostring(why)) return 'failed' end
            ctx:log('test: %dx %s dropped (removed when the test ends)', amount, tostring(item))
            return 'out'
        end, { late = function() SystemsTestItems.late(meta.systest, nil, item) end })
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
})

--- How close a search's viewer must stay to who they search (the inventory's leash).
local SEARCH_RANGE = 3

define({
    type = 'player.search', category = 'players', kind = 'action', title = 'Search Them', api = 'OpenPlayerInventory',
    desc = 'Opens a player\'s pockets to THIS pulse\'s player (a police search, a robbery): they may take what they find, standing within 3 m. Refused if someone else is already looking.',
    outputs = { 'out', 'refused' },
    labels = { refused = 'Refused' },
    values = { inputs = { { key = 'player', type = 'player', label = 'Who is searched' } } },
    run = function(ctx)
        local viewer = ctx:source(ctx:player())
        local _, src, p = playerIn(ctx)
        if not viewer or not p then return 'refused' end
        if viewer == src then ctx:log('nobody searches themselves') return 'refused' end
        local ok, why = OpenPlayerInventory(viewer, p.charId, SEARCH_RANGE)
        if not ok then ctx:log('search: %s', tostring(why)) return 'refused' end
        return 'out'
    end,
    dryRun = function(ctx)
        local viewer = ctx:source(ctx:player())
        local _, src, p = playerIn(ctx)
        if not viewer or not p or viewer == src then return 'refused' end
        tested(ctx, '%s\'s pockets opened to the searcher', tostring(p.fullName))
        return 'out'
    end,
})

-- ============================================
-- The whole server: time and weather
-- ============================================

local WORLD_DO = { 'set the time', 'set the weather', 'stop the clock', 'start the clock', 'blackout on', 'blackout off' }
--- A system changes the world at most this often (everyone sees each change; each is saved). Kept by
--- the switched-on copy, not the card (ten cards must not change it ten times).
local WORLD_EVERY_S = 10
local lastWorldChange = {}   -- [instance id] = when this copy last changed the world

define({
    type = 'world.set', category = 'world', kind = 'wait', title = 'Change the World', api = { 'SetTime', 'SetWeather', 'SetTimeFrozen', 'SetBlackout' },
    desc = 'Changes the time, the weather, the clock or the city\'s lights for everyone on the server. Once every 10 seconds a system at most; it stays as it is when the system is switched off.',
    props = { { key = 'what', kind = 'select', label = 'Do', options = WORLD_DO, default = WORLD_DO[2] },
              { key = 'weather', kind = 'select', label = 'Weather', options = Config.WeatherTypes or { 'CLEAR' }, default = 'CLEAR' } },
    outputs = { 'done', 'refused', 'timeout' },
    labels = { done = 'Done', refused = 'Refused', timeout = 'Took too long' },
    values = { inputs = { { key = 'hour', type = 'number', label = 'Hour', default = 12 }, { key = 'minute', type = 'number', label = 'Minute', default = 0 } } },
    run = function(ctx)
        local inst = ctx:instanceId()
        local now = ctx:now()
        local last = lastWorldChange[inst]
        if last and now - last < WORLD_EVERY_S * 1000 then ctx:log('the world was changed under %d seconds ago', WORLD_EVERY_S) return 'refused' end
        local what = ctx:prop('what')
        local hour, minute = math.floor(ctx:need('hour')) % 24, math.floor(ctx:need('minute')) % 60
        local weather = ctx:prop('weather')
        lastWorldChange[inst] = now
        ctx:call(function()
            local ok, why
            if what == WORLD_DO[1] then ok, why = TimeWeather.setTime(hour, minute)
            elseif what == WORLD_DO[2] then ok, why = TimeWeather.setWeather(weather)
            elseif what == WORLD_DO[3] or what == WORLD_DO[4] then ok, why = TimeWeather.setFrozen(what == WORLD_DO[3])
            else ok, why = TimeWeather.setBlackout(what == WORLD_DO[5]) end
            if not ok then ctx:log('%s: %s', tostring(what), tostring(why)) return 'refused' end
            return 'done'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
    dryRun = function(ctx)
        local what = ctx:prop('what')
        local detail = what == WORLD_DO[1] and ('%02d:%02d'):format(math.floor(ctx:need('hour')) % 24, math.floor(ctx:need('minute')) % 60)
            or what == WORLD_DO[2] and tostring(ctx:prop('weather')) or ''
        tested(ctx, 'the world: %s %s', tostring(what), detail)
        return 'done'
    end,
})
