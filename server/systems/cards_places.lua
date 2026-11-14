-- ============================================
-- Systems — cards about places: garages, areas, doors near, properties, shops
-- ============================================
--
-- Reads of whip's places, and opening a shop for this pulse's player. Whip's live records are read
-- and never handed out. None has a power: nothing here moves money or items or acts on anyone but the
-- pulse's own player (a shop opened for them is the shop's own screen, paid for there).

local C = SystemCards
local CALL_TIMEOUT_S = 15

local function define(def)
    def.side = 'server'
    local ok, why = C.define(def)
    if not ok then print('^1[whip_core:systems] card type refused: ' .. tostring(why) .. '^0') end
end

local function placeOf(x, y, z)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then return nil end
    return { x = x, y = y, z = z }
end

-- ============================================
-- Garages, areas, doors
-- ============================================

define({
    type = 'garage.info', category = 'world', kind = 'value', title = 'Garage Details', api = 'GetGarage',
    desc = 'A garage by its key: its name, where it is, and whether it is somebody\'s own.',
    props = { { key = 'garage', kind = 'text', label = 'Garage', required = true, maxLength = 64 } },
    values = { outputs = { { key = 'found', type = 'bool', label = 'Found' }, { key = 'name', type = 'text', label = 'Name' },
                           { key = 'place', type = 'vector', label = 'Place' }, { key = 'private', type = 'bool', label = 'Somebody\'s own' } } },
    value = function(ctx)
        local g = Garages.snapshot(ctx:prop('garage'))
        if not g then return { found = false, name = '', private = false } end
        return { found = true, name = tostring(g.name or g.key), place = placeOf(g.x, g.y, g.z), private = g.private == true }
    end,
})

define({
    type = 'area.cars', category = 'world', kind = 'value', title = 'Cars in Area', api = 'GetVehiclesInZone',
    desc = 'The cars whip looks after inside a zone (its key) now, 64 at most. Only zones the server keeps count.',
    props = { { key = 'area', kind = 'text', label = 'Zone key', required = true, maxLength = 64 } },
    values = { outputs = { { key = 'cars', type = 'list', label = 'Cars' }, { key = 'count', type = 'number', label = 'How many' } } },
    value = function(ctx)
        local key = ctx:prop('area')
        local z = type(key) == 'string' and key ~= '' and Zones.resolve(key) or nil
        if not z or z._reporters ~= nil then return { cars = {}, count = 0 } end
        local ids = {}
        for _, e in ipairs(Zones.getVehiclesInZone(key) or {}) do
            if e.vehicleId then ids[#ids + 1] = e.vehicleId end   -- a car whip does not look after has no id
        end
        table.sort(ids)
        local list = {}
        for i = 1, math.min(#ids, C.MAX_LIST) do list[i] = ids[i] end
        return { cars = list, count = #ids }
    end,
})

define({
    type = 'door.near', category = 'world', kind = 'value', title = 'Doors Near', api = 'GetDoorsNearby',
    desc = 'The whip doors within a distance of a place (measured flat), nearest first, 64 at most.',
    values = { inputs = { { key = 'place', type = 'vector', label = 'Place' }, { key = 'range', type = 'number', label = 'Within (m)', default = 10 } },
               outputs = { { key = 'doors', type = 'list', label = 'Doors' }, { key = 'count', type = 'number', label = 'How many' },
                           { key = 'nearest', type = 'door', label = 'Nearest' } } },
    value = function(ctx)
        local at = ctx:need('place')
        local range = math.max(0.5, math.min(50, ctx:need('range')))
        local found = {}
        for _, d in ipairs(Doors.getNearby(at.x, at.y, at.z, range) or {}) do
            found[#found + 1] = { id = d.doorId, d = (d.x - at.x) ^ 2 + (d.y - at.y) ^ 2 }
        end
        table.sort(found, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
        local list = {}
        for i = 1, math.min(#found, C.MAX_LIST) do list[i] = found[i].id end
        return { doors = list, count = #found, nearest = list[1] }
    end,
})

define({
    type = 'ground.near', category = 'items', kind = 'value', title = 'Items on the Ground', api = { 'GetGroundItemsNearby', 'GetGroundItem' },
    desc = 'How many of an item lie on the ground within a distance of a place (dropped, thrown, placed).',
    props = { { key = 'item', kind = 'item', label = 'Item', required = true } },
    values = { inputs = { { key = 'place', type = 'vector', label = 'Place' }, { key = 'range', type = 'number', label = 'Within (m)', default = 5 } },
               outputs = { { key = 'count', type = 'number', label = 'How many' }, { key = 'found', type = 'bool', label = 'Any' } } },
    value = function(ctx)
        local at = ctx:need('place')
        local item = ctx:prop('item')
        local n = 0
        for _, g in ipairs(GroundItems.getNearby(at.x, at.y, at.z, math.max(0.5, math.min(50, ctx:need('range')))) or {}) do
            if g.item == item then n = n + (tonumber(g.amount) or 1) end
        end
        return { count = n, found = n > 0 }
    end,
})

-- ============================================
-- Properties
-- ============================================

define({
    type = 'home.info', category = 'world', kind = 'value', title = 'Property Details', api = 'GetProperty',
    desc = 'A property (from Property Here): its name, and whose it is. Who holds its keys is private.',
    values = { inputs = { { key = 'property', type = 'number', label = 'Property' } },
               outputs = { { key = 'found', type = 'bool', label = 'Found' }, { key = 'name', type = 'text', label = 'Name' },
                           { key = 'owner', type = 'character', label = 'Owner' } } },
    value = function(ctx)
        local rec = Properties.get(math.floor(ctx:need('property')))
        if not rec then return { found = false, name = '' } end
        return { found = true, name = tostring(rec.name or ''), owner = rec.ownerCharId }
    end,
})

define({
    type = 'home.hasKey', category = 'world', kind = 'value', title = 'Has a Key?', api = 'HasPropertyAccess',
    desc = 'Yes or no: may a player go into a property: they own it, or hold a key to it.',
    values = { inputs = { { key = 'player', type = 'player', label = 'Player' }, { key = 'property', type = 'number', label = 'Property' } },
               outputs = { { key = 'result', type = 'bool', label = 'Yes?' } } },
    value = function(ctx)
        local src = ctx:source(ctx:need('player'))
        local p = src and Players[src]
        if not p or not p.charId then return { result = false } end
        return { result = Properties.hasAccess(math.floor(ctx:need('property')), p.charId) == true }
    end,
})

-- ============================================
-- Shops
-- ============================================

--- A shop prop's shop (its key, or its number), or nil.
local function shopOf(ctx)
    local ref = ctx:prop('shop')
    if type(ref) ~= 'string' or ref == '' then return nil end
    return Shops.getByKey(ref) or Shops.getDef(tonumber(ref) or -1)
end

local function shopProp() return { key = 'shop', kind = 'text', label = 'Shop (its key)', required = true, maxLength = 64 } end

define({
    type = 'shop.info', category = 'world', kind = 'value', title = 'Shop Details', api = 'GetShop',
    desc = 'A shop by its key: its name and where it is.',
    props = { shopProp() },
    values = { outputs = { { key = 'found', type = 'bool', label = 'Found' }, { key = 'name', type = 'text', label = 'Name' },
                           { key = 'place', type = 'vector', label = 'Place' } } },
    value = function(ctx)
        local def = shopOf(ctx)
        if not def then return { found = false, name = '' } end
        return { found = true, name = tostring(def.name or ''), place = placeOf(def.x, def.y, def.z) }
    end,
})

define({
    type = 'shop.price', category = 'world', kind = 'wait', title = 'Shop Price', api = { 'GetShopCatalog', 'GetShopStock', 'GetShopPrices' },
    desc = 'What a shop sells an item for, and how many it has (a shop that never runs out: Unlimited). Not Sold if it does not sell it.',
    props = { shopProp(), { key = 'item', kind = 'item', label = 'Item', required = true } },
    outputs = { 'sold', 'notSold', 'timeout' },
    labels = { sold = 'Sold', notSold = 'Not sold', timeout = 'Took too long' },
    values = { outputs = { { key = 'price', type = 'number', label = 'Price ($)' }, { key = 'stock', type = 'number', label = 'In stock' },
                           { key = 'unlimited', type = 'bool', label = 'Unlimited' } } },
    run = function(ctx)
        local def = shopOf(ctx)
        if not def then ctx:log('there is no shop "%s"', tostring(ctx:prop('shop'))) return 'notSold' end
        local item = ctx:prop('item')
        if def.mode ~= 'stocked' then
            local price = type(def.catalog) == 'table' and tonumber(def.catalog[item]) or nil
            if not price then return 'notSold' end
            return 'sold', { price = price, stock = 0, unlimited = true }
        end
        local shopId = def.shopId
        ctx:call(function()
            -- The stock waits on the shop's container and its prices (the database, the first time).
            local stock = Shops.getStock(shopId)
            local price, count = nil, 0
            for _, s in pairs(stock or {}) do
                if s.item == item and s.forSale then
                    count = count + (tonumber(s.amount) or 1)
                    local p = tonumber(s.price)
                    if p and (not price or p < price) then price = p end
                end
            end
            if not price then return 'notSold' end
            return 'sold', { price = price, stock = count, unlimited = false }
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
})

--- How near a shop its customer must stand (the shop's own open event checks the same).
local SHOP_RANGE = 15

define({
    type = 'shop.open', category = 'world', kind = 'wait', title = 'Open Shop',
    desc = 'Opens a shop\'s screen for THIS pulse\'s player, standing within 15 m of it. They buy there, at its prices.',
    props = { shopProp() },
    outputs = { 'opened', 'refused', 'timeout' },
    labels = { opened = 'Opened', refused = 'Refused', timeout = 'Took too long' },
    values = { outputs = { { key = 'why', type = 'text', label = 'Why not' } } },
    run = function(ctx)
        local def = shopOf(ctx)
        if not def then return 'refused', { why = 'no such shop' } end
        local me = ctx:player()
        local src = ctx:source(me)
        local p = src and Players[src]
        if not p then return 'refused', { why = 'not here' } end
        local at = placeOf(def.x, def.y, def.z)
        if at then
            local ped = GetPlayerPed(src)
            local c = ped and ped ~= 0 and GetEntityCoords(ped)
            if not c or (c.x - at.x) ^ 2 + (c.y - at.y) ^ 2 + (c.z - at.z) ^ 2 > SHOP_RANGE * SHOP_RANGE then
                return 'refused', { why = 'too far from the shop' }
            end
        end
        local shopId = def.shopId
        ctx:call(function()
            if not ctx:source(me) then return 'refused', { why = 'not here' } end
            local ok, why = Shops.openFor(src, Players[src], shopId)
            if not ok then return 'refused', { why = tostring(why) } end
            return 'opened'
        end)
        ctx:after(CALL_TIMEOUT_S * 1000, 'timeout')
        return nil
    end,
})
