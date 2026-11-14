-- ============================================
-- SHOPS — Server Module
-- Provides: cache, CRUD, pricing, purchase logic
-- ============================================

Shops = {}

-- ============================================
-- Cache
-- ============================================

Shops.cache       = {}   -- [shopId] = shop definition
Shops.priceCache  = {}   -- [containerId] = { [itemKey] = { price, forSale } }  (stocked shops)
Shops._openShops  = {}   -- [source] = shopId  (Shops.openShopOf from outside this file)
Shops._keyIndex   = {}   -- [key] = shopId

--- The /whip Shops panel's refresh, handed over by devtools.lua (Shops.setPanelRefresh).
local panelRefresh = nil

---@param fn function|nil
function Shops.setPanelRefresh(fn)
    panelRefresh = fn
end

--- The shop this player has open, or nil.
---@param source number
---@return number|nil shopId
function Shops.openShopOf(source)
    return Shops._openShops[source]
end

-- ============================================
-- Basket sessions
-- ============================================
--
-- Global, and named to match _panelSessions, because the `basket` store kind in stores.lua
-- resolves through it (lazily, at move time) and that file loads BEFORE this one.
--
-- A line has no price of its own: a shop prices per ITEM, so a line costs what the shop asks for
-- that item NOW. The screen shows it, the till charges it, and the till refuses if it changed after
-- the player last saw the total (Shops.purchase's expectedTotal).
---@diagnostic disable-next-line: lowercase-global -- a global on purpose (see above): stores.lua reads it
_basketSessions = {}   -- [source] = { items = { [slot] = { item, amount, metadata } }, slots = n, checkout = bool }

--- How many lines a basket has: Config.ShopBasketSlots, held to 1-50 (the basket's events address
--- lines up to 50).
---@return integer
local function basketSlots()
    local n = math.tointeger(tonumber(Config.ShopBasketSlots))
    if not n then return 10 end
    return math.max(1, math.min(50, n))
end

--- An item's name as a player reads it.
---@param itemKey string
---@return string
local function itemName(itemKey)
    local def = Config.Items[itemKey]
    return (def and def.name) or tostring(itemKey)
end

--- The store the player's currently open shop sells from: a stocked shop's real container (one
--- persistence path for its goods), or the synthetic `shop` kind for infinite and NPC shops.
---@param source number
---@return table|nil store
---@return string|nil err
function Shops.sellStore(source)
    local shopId = Shops._openShops[source]
    if not shopId then return nil, 'no shop open' end

    local def = Shops.getDef(shopId)
    if not def then return nil, 'shop not found' end

    if def.mode == 'stocked' then
        if not def.containerId then return nil, 'shop has no stock container' end
        return Stores.container(def.containerId)
    end
    return Stores.shop(shopId)
end

--- What one of an item costs at a shop, from the SERVER'S OWN records — nil when the shop does not
--- sell it. Per ITEM in every mode: an infinite or NPC shop's catalog line; a stocked shop's item
--- price (shop_item_prices), and only while that item is marked for sale.
---
--- Never from the client, and never from the basket: a price that travelled through the browser is
--- a price the buyer chose.
---@param def table|nil  the shop
---@param itemKey string
---@return number|nil price
function Shops.itemPrice(def, itemKey)
    if not def or type(itemKey) ~= 'string' then return nil end

    if def.mode == 'stocked' then
        if not def.containerId then return nil end
        local priceData = Shops.getItemPrice(def.containerId, itemKey)
        if not priceData or not priceData.forSale then return nil end
        return priceData.price
    end

    local entry = def.catalog and def.catalog[itemKey]
    if not entry then return nil end
    -- Catalogs are `item = price`, whole numbers: create, update and load all normalise to that
    -- (see validateCatalog). A number, and never negative: anything else is not for sale.
    local price = tonumber(entry)
    if not price or price ~= price or price < 0 or price == math.huge then return nil end
    return price
end

--- What one of an item costs at the shop this player has open.
---@param source number
---@param itemKey string
---@return number|nil price
function Shops.priceFor(source, itemKey)
    local shopId = Shops._openShops[source]
    if not shopId then return nil end
    return Shops.itemPrice(Shops.getDef(shopId), itemKey)
end

--- A player has just opened a shop: the session, and a basket as big as Config.ShopBasketSlots says.
--- Ended only by Shops.endSession.
---@param source number
---@param shopId number
function Shops.beginSession(source, shopId)
    Shops._openShops[source] = shopId
    _basketSessions[source] = { items = {}, slots = basketSlots() }
end

--- How far from the counter a shop session keeps working, in metres. openShop's own radius is
--- 15; the slack keeps a player shuffling at the till from being refused mid-purchase.
local SHOP_KEEP_RANGE = 20.0

--- Is this player still standing at the shop they have open? openShop checks the distance once;
--- every later action asks this.
---@param source number
---@return boolean
function Shops.inRange(source)
    local shopId = Shops._openShops[source]
    local def = shopId and Shops.getDef(shopId)
    if not def or not def.x then return false end
    return IsPlayerNear(source, def.x, def.y, def.z, SHOP_KEEP_RANGE)
end

--- Is any customer shopping at a stocked shop whose shelf is this container?
---
--- Customers reach the stock through their session, not as container viewers, so the container's
--- own viewer count says nothing about them. Containers.unloadInventory asks this before dropping
--- a cache.
---@param containerId number
---@return boolean
function Shops.containerInUse(containerId)
    for _, shopId in pairs(Shops._openShops) do
        local def = Shops.getDef(shopId)
        if def and def.mode == 'stocked' and def.containerId == containerId then
            return true
        end
    end
    return false
end

--- Is a basket for this player in the middle of paying?
---@param source number
---@return boolean
function Shops.isCheckingOut(source)
    local session = _basketSessions[source]
    return session ~= nil and session.checkout == true
end

local slotAccepting = Stores.slotAccepting

--- Move up to `want` units between two slots in as few mover calls as it takes: a batch goes by
--- moveAmount, and one the mover refuses (a stack cap, a weight limit) is halved and retried, so what
--- fits still moves.
---
--- Never the whole source through moveAmount: at the full amount it hands over to Stores.move,
--- which SWAPS when the two stacks cannot merge. The last unit goes by moveOne instead. (An infinite
--- shelf's row always reads as one unit, so it is a moveOne per unit.)
---@return number moved
local function moveUnits(fromStore, fromSlot, toStore, toSlot, want)
    local moved, step = 0, want
    while moved < want and step >= 1 do
        local d = fromStore.kind.get(fromStore.handle, fromSlot)
        local have = d and d.amount or 0
        if have < 1 then break end

        local n = math.min(step, want - moved, have)
        if n >= have then n = have - 1 end

        local ok
        if n <= 1 then
            n = 1
            ok = Stores.moveOne(fromStore, fromSlot, toStore, toSlot)
        else
            ok = Stores.moveAmount(fromStore, fromSlot, toStore, toSlot, n)
        end

        if ok then
            moved = moved + n
        else
            step = math.floor(n / 2)
        end
    end
    return moved
end

--- Up to `want` of an item from the shelf into the basket: onto `prefer` (a line being raised) while
--- it stacks there, then wherever the basket takes it — a line of the same thing first, then an empty
--- line (Stores.slotAccepting). Answers how many moved, and whether the basket ran out of lines.
---
--- Every shelf slot holding the item is drawn on, in order: a stocked shelf can hold one item in
--- several stacks. An infinite shelf has the one row, which never empties.
---@param shelf table
---@param basket table
---@param itemKey string
---@param want number
---@param prefer number|nil   a basket line to fill first
---@param touched table|nil   collects the shelf slots that gave something
---@return number moved
---@return boolean full
local function pullItem(shelf, basket, itemKey, want, prefer, touched)
    local kind, handle = shelf.kind, shelf.handle
    local slots = kind.slots(handle)
    local moved, full = 0, false
    local s, guard = 1, 0
    -- Bounded: each pass moves something, steps to the next slot, or stops.
    while moved < want and s <= slots and guard < 4000 do
        guard = guard + 1
        local d = kind.get(handle, s)
        if not d or d.item ~= itemKey then
            s = s + 1
        else
            local n = 0
            local line = prefer and basket.kind.get(basket.handle, prefer)
            if line and line.item == itemKey then
                n = moveUnits(shelf, s, basket, prefer, want - moved)
            end
            if n == 0 then
                prefer = nil   -- that line takes no more of these
                local to = slotAccepting(basket, itemKey, 1, d.metadata)
                if not to then full = true break end
                n = moveUnits(shelf, s, basket, to, want - moved)
            end
            if n == 0 then
                s = s + 1
            else
                moved = moved + n
                if touched then touched[s] = true end
            end
        end
    end
    return moved, full
end

--- Up to `want` units of basket line `slot` back onto a STOCKED shelf: onto the same item where it
--- stacks, else the first free slot (Stores.slotAccepting, the merge-or-empty answer every give uses).
--- Asked for the whole remainder first, so the move that follows never has to swap. Where it lands
--- doesn't change what it costs (prices are per item).
---@return number back
local function returnUnits(basket, slot, shelf, want, touched)
    local back = 0
    for _ = 1, 8 do
        local entry = basket.kind.get(basket.handle, slot)
        if not entry or back >= want then break end
        local n = math.min(want - back, entry.amount or 1)
        local dest = slotAccepting(shelf, entry.item, n, entry.metadata)
            or slotAccepting(shelf, entry.item, 1, entry.metadata)
        if not dest then break end
        local moved = moveUnits(basket, slot, shelf, dest, n)
        if moved == 0 then break end
        back = back + moved
        if touched then touched[dest] = true end
    end
    return back
end

--- Take `n` units off a line from an INFINITE shelf. Its shelf is a catalog: the goods were never
--- taken from any stock, so nothing goes back anywhere — they are simply not in the basket any more.
---@return number dropped
local function dropUnits(session, slot, n)
    local entry = session.items[slot]
    if not entry then return 0 end
    local have = entry.amount or 1
    if n >= have then
        session.items[slot] = nil
        return have
    end
    entry.amount = have - n
    return n
end

--- End a shop session, returning anything left unpaid. The only place a shop session ends.
---
--- A stocked shop's basket holds goods taken out of real stock, so every line goes back onto the
--- shelf (onto the same item, or a free slot: returnUnits), and anything with no room is written down
--- as lost, never dropped silently. Infinite shops return nothing: the shelf never went down.
---@param source number
---@param deferWrite boolean|nil  queue the stock write instead of flushing it now (resource stop)
---@return number|nil shopId  the shop that was open, if any
function Shops.endSession(source, deferWrite)
    local shopId  = Shops._openShops[source]
    local session = _basketSessions[source]
    local returned = false

    if session and shopId and next(session.items) ~= nil then
        local def = Shops.getDef(shopId)
        if def and def.mode == 'stocked' and def.containerId then
            local basket = Stores.basket(source)
            local stock  = Stores.container(def.containerId)

            if basket and stock then
                -- Snapshot the slots first: the movers clear session.items as they go, and
                -- iterating a table while clearing keys out of it skips entries.
                local slots = {}
                for slot in pairs(session.items) do slots[#slots + 1] = slot end
                table.sort(slots)

                -- No `break` on a full shelf: every line is tried.
                for _, slot in ipairs(slots) do
                    local entry = session.items[slot]
                    if entry and returnUnits(basket, slot, stock, entry.amount or 1) > 0 then
                        returned = true
                    end
                    local left = session.items[slot]
                    if left then
                        print(('[whip_core:shops] CRITICAL: shop "%s" stock has no room for %s x%s returned '
                            .. 'from src %s\'s basket — lost'):format(tostring(def.name), tostring(left.item),
                            tostring(left.amount), tostring(source)))
                        -- On the record, not only in the console: every path that destroys items
                        -- writes a lost row, so the loss shows in the item's timeline.
                        local p = Players[source]
                        Log.item(p and p.charId, 'lost', left, {
                            detail = ('no room to return it to shop "%s" stock'):format(tostring(def.name)),
                        })
                    end
                end

            end
        end
    end

    -- The session ends before anything yields: during the flush below, an open basket could pull
    -- more stock into a basket about to be wiped.
    _basketSessions[source] = nil
    Shops._openShops[source] = nil
    Shops.talkEnded(source)

    if returned then
        local def = Shops.getDef(shopId)
        local stockStore = def and def.containerId and Stores.container(def.containerId)
        if stockStore then
            -- Written back now, as the purchase path does: stock visibly back on the shelf must
            -- survive a crash. Except on a resource stop: the returns are only queued (saveAll
            -- doesn't yield) and step 60 of server/lifecycle.lua (Stores.dispatchOwed) sends them;
            -- this is step 20, and a flush would yield inside the stop handler.
            if deferWrite then
                pcall(Stores.saveAll, { stockStore })
            else
                Shops.refreshShop(shopId)   -- the others at the shop see the goods come back
                pcall(Stores.flushNow, stockStore)
            end
        end
    end
    return shopId
end

--- A shop left open from a distance is closed, and its basket goes back on the shelf: a stocked
--- shop's basket holds REAL stock, which a screen left up (or never closed) would keep from everyone.
--- A basket at the till is left alone: checkout owns it until it finishes.
Every('shops: walked away', 10000, function()
    local away = {}
    for src in pairs(Shops._openShops) do
        if not Shops.isCheckingOut(src) and not Shops.inRange(src) then away[#away + 1] = src end
    end
    for _, src in ipairs(away) do
        local ok, err = pcall(Shops.endSession, src)
        if ok then
            TriggerClientEvent('whip_core:client:shopClosed', src)
        else
            print(('[whip_core:shops] ERROR closing the shop src %s walked away from: %s')
                :format(tostring(src), tostring(err)))
        end
    end
end)

--- whip_core is stopping: every basket goes back on its shelf first.
---
--- Baskets live only in memory. Step 20 of whip_core's stop (server/lifecycle.lua), so it runs before
--- step 60 sends the owed writes.
CoreStop.add(20, 'shops: return baskets', function()
    local open = {}
    for src in pairs(Shops._openShops) do open[#open + 1] = src end
    for _, src in ipairs(open) do
        local ok, err = pcall(Shops.endSession, src, true)
        if not ok then
            print(('[whip_core:shops] ERROR returning basket for src %s on stop: %s'):format(tostring(src), tostring(err)))
        end
    end
end)

--- Can this player carry the whole basket? nil when they can, or why not — asked the way the till asks
--- before it takes any money: every line must find room in the main pockets, the lines that need an
--- EMPTY pocket slot must not need more than there are, and the weight of it all must fit.
---@param source number
---@param session table
---@return string|nil why
local function cannotCarry(source, session)
    local pockets = Stores.player(source, 'player')
    if not pockets then return 'Could not reach your inventory' end
    local kind, handle = pockets.kind, pockets.handle

    local freeSlots = 0
    for s = 1, kind.slots(handle) do
        if not kind.get(handle, s) then freeSlots = freeSlots + 1 end
    end

    local needFree = 0
    for _, entry in pairs(session.items) do
        local amount = entry.amount or 1
        local dest = slotAccepting(pockets, entry.item, amount, entry.metadata)
        if not dest then
            return ('No room in your pockets for %s x%d'):format(itemName(entry.item), amount)
        end
        if not kind.get(handle, dest) then needFree = needFree + 1 end
    end
    if needFree > freeSlots then
        return 'Not enough free pocket slots for everything in your basket'
    end

    -- The same sum delivery's own move makes (Stores.move), so this never says yes to what it refuses.
    local basket = Stores.basket(source)
    if basket and Stores.weightOf(pockets) + Stores.weightOf(basket) > kind.maxWeight(handle) then
        return 'That is more than you can carry'
    end
    return nil
end

--- The shop screen, exactly as the client should draw it: the shop's goods fill the middle of the
--- inventory, and the basket the right.
---
--- The shelf is per item: a stocked shop keeps its goods on container slots, but a customer buys
--- "drink", not "slot 14": every slot holding an item for sale is one entry, its stock the units
--- across them. An item priced for sale with none left stays on the shelf, SOLD OUT. The order and
--- the tabs are the shop's own (settings.layout, settings.categories — config.lua §9); anything not
--- placed follows, A to Z by name. Goods not for sale are not on the shopfront at all.
---
--- The client asks for things by ITEM (basketAdd) and by basket LINE (basketSetQuantity), never by
--- shelf slot, so nothing here has to line up with how a container numbers its slots.
---@param source number
---@return table
function Shops.buildScreenState(source)
    local state = {
        shelf = {}, categories = {}, uncategorised = false,
        basket = {}, basketSlots = 0, basketTotal = 0, basketWeight = 0,
    }
    local shopId = Shops._openShops[source]
    local def = shopId and Shops.getDef(shopId)
    if not def then return state end

    local settings = type(def.settings) == 'table' and def.settings or {}
    local layout = type(settings.layout) == 'table' and settings.layout or {}

    -- ---- The goods, one entry per item ----
    local stock, order = {}, {}
    if def.mode == 'stocked' then
        -- The prices first: the sold-out entries below are read off them (a no-op once loaded).
        if def.containerId then Shops.loadPrices(def.containerId) end
        local sell = Shops.sellStore(source)
        if sell then
            local kind, handle = sell.kind, sell.handle
            for slot = 1, kind.slots(handle) do
                local d = kind.get(handle, slot)
                if d and d.item then
                    if not stock[d.item] then
                        stock[d.item] = 0
                        order[#order + 1] = d.item
                    end
                    stock[d.item] = stock[d.item] + (d.amount or 1)
                end
            end
        end
        -- Sold out: priced for sale, and none on the shelf.
        for item, p in pairs(def.containerId and Shops.priceCache[def.containerId] or {}) do
            if p.forSale and not stock[item] then
                stock[item] = 0
                order[#order + 1] = item
            end
        end
    else
        for item in pairs(def.catalog or {}) do order[#order + 1] = item end
    end

    local entries = {}
    for _, item in ipairs(order) do
        local price = Shops.itemPrice(def, item)
        -- An item the server does not know cannot be bought (it has no weight, no stack rule), so it
        -- is not shown.
        if price and Config.Items[item] then
            local place = type(layout[item]) == 'table' and layout[item] or {}
            entries[#entries + 1] = {
                item     = item,
                price    = price,
                stock    = def.mode == 'stocked' and stock[item] or nil,   -- nil: it never runs out
                category = type(place.category) == 'string' and place.category ~= '' and place.category or nil,
                _order   = tonumber(place.order),
                _name    = itemName(item):lower(),
            }
        end
    end
    table.sort(entries, function(a, b)
        if a._order ~= b._order then
            if a._order and b._order then return a._order < b._order end
            return a._order ~= nil   -- placed goods first
        end
        if a._name ~= b._name then return a._name < b._name end
        return a.item < b.item
    end)

    local used = {}
    for _, e in ipairs(entries) do
        e._order, e._name = nil, nil
        state.shelf[#state.shelf + 1] = e
        if e.category then used[e.category] = true else state.uncategorised = true end
    end

    -- ---- The tabs: the shop's own order, and only those with goods in them ----
    local seen = {}
    if type(settings.categories) == 'table' then
        for _, c in ipairs(settings.categories) do
            if type(c) == 'string' and used[c] and not seen[c] then
                seen[c] = true
                state.categories[#state.categories + 1] = c
            end
        end
    end
    -- A category an item names that the list does not: after the listed ones, A to Z.
    local extra = {}
    for c in pairs(used) do
        if not seen[c] then extra[#extra + 1] = c end
    end
    table.sort(extra)
    for _, c in ipairs(extra) do state.categories[#state.categories + 1] = c end

    -- ---- For someone who may arrange the shelf: every tab, empty ones too (Edit Shelf) ----
    if Shops.canArrange(source, def) then
        state.canArrange = true
        -- The shelf's layout as of this screen: Edit Shelf saves against it (Shops.setLayout)
        state.layoutRev = math.tointeger(tonumber(settings.layoutRev)) or 0
        state.allCategories = {}
        for _, c in ipairs(type(settings.categories) == 'table' and settings.categories or {}) do
            if type(c) == 'string' then state.allCategories[#state.allCategories + 1] = c end
        end
    end

    -- ---- The basket, line by line, at the shop's price now ----
    local session = _basketSessions[source]
    if session then
        state.basketSlots = session.slots
        local slots = {}
        for slot in pairs(session.items) do slots[#slots + 1] = slot end
        table.sort(slots)
        for _, slot in ipairs(slots) do
            local entry = session.items[slot]
            local amount = entry.amount or 1
            local unit = Shops.itemPrice(def, entry.item)   -- nil: no longer for sale (the till refuses it)
            state.basket[#state.basket + 1] = {
                slot = slot, item = entry.item, amount = amount, metadata = entry.metadata, price = unit,
            }
            if unit then state.basketTotal = state.basketTotal + unit * amount end
        end
        local basket = Stores.basket(source)
        state.basketWeight = basket and Stores.weightOf(basket) or 0
        -- The pockets are hidden while shopping, so the screen says whether it will all fit
        -- instead (the till's own question).
        if #state.basket > 0 then state.cannotCarry = cannotCarry(source, session) end
    end

    return state
end

--- After the shelf changed under a customer: the stock saved, anyone looking at the stock container
--- told (an employee's stock view), and every customer at the shop redrawn. An infinite shelf is a
--- catalog, with nothing to save or show. (The movers neither mark the shelf for saving nor tell its
--- viewers, so this does.)
local function shelfChanged(def, shelf, touched, source)
    if def.mode ~= 'stocked' or not next(touched) then return end
    local slots = {}
    for s in pairs(touched) do slots[#slots + 1] = s end
    Stores.saveAll({ shelf })
    Stores.publishSlots(shelf, slots, source)
    Shops.refreshShop(def.shopId)
end

--- What every basket action checks first. Answers the session, the shop, its shelf and the basket —
--- or false and why.
local function basketAction(source)
    local session = _basketSessions[source]
    if not session then return false, 'No shop open' end
    -- Not while paying: the till prices the basket, yields on the bank, then delivers, and a change
    -- in that gap would be delivered at the old total.
    if session.checkout then return false, 'Paying — wait a moment' end
    if not Shops.inRange(source) then return false, 'Too far from shop' end
    local def = Shops.getDef(Shops._openShops[source])
    local shelf, basket = Shops.sellStore(source), Stores.basket(source)
    if not def or not shelf or not basket then return false, 'The shop is not available' end
    return session, def, shelf, basket
end

--- How many of an item the basket holds, all its lines together (a serialled item never stacks).
--- What shop talk is told, before and after a change (server/shop_talk.lua).
local function basketCount(session, itemKey)
    local n = 0
    for _, entry in pairs(session.items) do
        if entry.item == itemKey then n = n + (entry.amount or 1) end
    end
    return n
end

--- Put `want` of an item off the shelf into the basket: the shop screen's click, drag and pad A.
---
--- Answers how many went in, or false and why. Part of it is still an answer: three left on a shelf
--- asked for five puts three in, and says why the rest did not.
---@param source number
---@param itemKey string
---@param want number
---@return number|false added
---@return string|nil why
function Shops.addToBasket(source, itemKey, want)
    local session, def, shelf, basket = basketAction(source)
    if not session then return false, def --[[@as string]] end
    ---@cast def table   -- with a session come the shop, its shelf and the basket
    ---@cast shelf -nil
    ---@cast basket -nil
    if not Shops.itemPrice(def, itemKey) then return false, 'That is not for sale' end

    local touched = {}
    local before = basketCount(session, itemKey)
    local added, full = pullItem(shelf, basket, itemKey, want, nil, touched)
    shelfChanged(def, shelf, touched, source)
    Shops.pushScreen(source)
    Shops.talkBasket(source, itemKey, before, basketCount(session, itemKey))

    if added == 0 then
        if full then return false, 'Your basket is full' end
        return false, def.mode == 'stocked' and 'Sold out' or 'That will not go in your basket'
    end
    if added < want then
        return added, full and 'Your basket is full' or ('Only %d left'):format(added)
    end
    return added
end

--- Set one basket line to an exact quantity: the line's minus and plus, and 0 to take it out.
---
--- More comes off the shelf onto this line first, then onto any line that takes it (a serialled item
--- never stacks). Less goes back onto a stocked shelf, or simply leaves the basket of an infinite one.
--- Through the movers, and the push at the end draws what actually happened.
---@param source number
---@param basketSlot number
---@param quantity number
---@return boolean ok
---@return string|nil why  for a change made only in part
function Shops.setLine(source, basketSlot, quantity)
    local session, def, shelf, basket = basketAction(source)
    if not session then return false, def --[[@as string]] end
    ---@cast def table   -- with a session come the shop, its shelf and the basket
    ---@cast shelf -nil
    ---@cast basket -nil
    local entry = session.items[basketSlot]
    if not entry then return false, 'That is not in your basket' end

    local have = entry.amount or 1
    local touched, why = {}, nil
    local itemKey = entry.item
    local before = basketCount(session, itemKey)

    if quantity > have then
        if not Shops.itemPrice(def, entry.item) then
            why = 'That is no longer for sale'
        else
            local want = quantity - have
            local added, full = pullItem(shelf, basket, entry.item, want, basketSlot, touched)
            if added < want then
                if full then
                    why = 'Your basket is full'
                elseif def.mode == 'stocked' then
                    why = 'That is all there is'
                end
            end
        end
    elseif quantity < have then
        local excess = have - quantity
        if def.mode == 'stocked' then
            if returnUnits(basket, basketSlot, shelf, excess, touched) < excess then
                why = 'The shelf has no room to take that back'
            end
        else
            dropUnits(session, basketSlot, excess)
        end
    end

    shelfChanged(def, shelf, touched, source)
    Shops.pushScreen(source)
    Shops.talkBasket(source, itemKey, before, basketCount(session, itemKey))
    return true, why
end

--- Make the basket hold exactly `want` of an item, all its lines together: the shop screen's plus and
--- minus, a number typed in, a held button.
---
--- A total, not a step, so the screen can show the number at once and send only the newest one: twenty
--- quick clicks are one request for 20, and a request sent twice changes nothing. More comes off the
--- shelf as addToBasket takes it; less comes off the lines in `from` first (the lines pressed on, newest
--- first: several taken out within one round trip are all kept in mind), then the item's last lines,
--- as the card's minus always did.
---@param source number
---@param itemKey string
---@param want number
---@param from number[]|nil  basket lines to take from first, in that order
---@return number|false total  what the basket holds of it now, or false
---@return string|nil why       why not, or why not all of it
function Shops.setItemTotal(source, itemKey, want, from)
    local session, def, shelf, basket = basketAction(source)
    if not session then return false, def --[[@as string]] end
    ---@cast def table   -- with a session come the shop, its shelf and the basket
    ---@cast shelf -nil
    ---@cast basket -nil
    local before = basketCount(session, itemKey)
    local touched, why = {}, nil

    if want > before then
        if not Shops.itemPrice(def, itemKey) then return false, 'That is not for sale' end
        local need = want - before
        local added, full = pullItem(shelf, basket, itemKey, need, nil, touched)
        if added < need then
            if full then
                why = 'Your basket is full'
            elseif def.mode == 'stocked' then
                why = added == 0 and before == 0 and 'Sold out' or 'That is all there is'
            else
                why = 'That will not go in your basket'
            end
        end
    elseif want < before then
        local excess = before - want
        local lines = {}
        for slot, entry in pairs(session.items) do
            if entry.item == itemKey then lines[#lines + 1] = slot end
        end
        local rank = {}
        for i, slot in ipairs(type(from) == 'table' and from or {}) do rank[slot] = rank[slot] or i end
        table.sort(lines, function(a, b)
            local ra, rb = rank[a], rank[b]
            if ra and rb then return ra < rb end
            if ra then return true elseif rb then return false end
            return a > b
        end)
        for _, slot in ipairs(lines) do
            if excess <= 0 then break end
            local entry = session.items[slot]
            local take = entry and math.min(entry.amount or 1, excess) or 0
            if take > 0 then
                if def.mode == 'stocked' then
                    local back = returnUnits(basket, slot, shelf, take, touched)
                    excess = excess - back
                    if back < take then
                        why = 'The shelf has no room to take that back'
                        break
                    end
                else
                    excess = excess - dropUnits(session, slot, take)
                end
            end
        end
    end

    shelfChanged(def, shelf, touched, source)
    Shops.pushScreen(source)
    local after = basketCount(session, itemKey)
    Shops.talkBasket(source, itemKey, before, after)
    return after, why
end

-- ---- The shop screen's actions ----
--
-- A refusal is `false, 'why'` (shown and recorded); a change made only in part says why the
-- rest was not. Both name things the server can check — an item key, a basket line — never a shelf
-- slot, and never a price.

SecureEvent('whip_core:server:basketAdd', {
    -- A click per unit is ordinary shopping: the default limit (100 ms, burst 10) stops a held key,
    -- not a shopper.
    params = { {'item', 'key', 50}, {'amount', 'amount', 999} },
}, function(source, _, itemKey, amount)
    local added, why = Shops.addToBasket(source, itemKey, amount)
    if not added then return false, why end
    if why then NotifyPlayer(source, why, 'warning', 3000) end
end)

--- Set how many of an item the basket holds (Shops.setItemTotal). A callback, so the screen knows when
--- its number has landed and can send the next one: it keeps one on its way per item, the newest
--- total the player asked for (html/js/shops.js). A held button on a short ping lands one about every
--- 40 ms, so the limit is roomy; a total sent twice changes nothing. Up to 999 a call, as basketAdd
--- (an infinite shelf moves one unit at a time).
--- `from`: the basket lines to take from first, newest first (a list; up to 50 slots of 1-50).
--- Answers { ok, total } — the basket's real count, which the screen's push draws anyway — and says
--- why when not all of it happened.
SecureCallback('whip_core:basketSetItem', {
    rateLimit = 30,
    burst     = 20,
    params    = { {'item', 'key', 50}, {'quantity', 'int', 0, 999}, {'from', 'any'} },
}, function(source, _, itemKey, quantity, from)
    local lines, seen = {}, {}
    local list = type(from) == 'table' and from or {}
    for i = 1, math.min(#list, 50) do
        local slot = math.tointeger(tonumber(list[i]))
        if slot and slot >= 1 and slot <= 50 and not seen[slot] then
            seen[slot] = true
            lines[#lines + 1] = slot
        end
    end
    local total, why = Shops.setItemTotal(source, itemKey, quantity, lines)
    if why then NotifyPlayer(source, why, total and 'warning' or 'error', 3000) end
    if not total then return { ok = false, why = why } end
    return { ok = true, total = total }
end)

-- ============================================
-- Arranging the shelf
-- ============================================
--
-- settings.categories is the tabs, in order; settings.layout puts each item in one and gives it a
-- place: { water = { category = 'Drinks', order = 1 } } (config.lua §9). buildScreenState reads
-- both. They are set from the shop screen's Edit Shelf (its managers and whip's admins), from the
-- SetShopLayout export, or from a shop's settings in config.lua or EnsureShop.

local MAX_TABS, MAX_TAB_LEN, MAX_PLACED = 12, 24, 500

--- May this player arrange this shop's shelf? Its job's managers (canManage, as Manage Stock asks),
--- and whip's admins. A shop with no job has only the admins.
---@param source number
---@param def table
---@return boolean
function Shops.canArrange(source, def)
    if not def then return false end
    if DevTools.isAllowed(source) then return true end   -- developer mode on, too
    local p = Players[source]
    return def.jobId ~= nil and p ~= nil and Jobs.hasPermission(p.charId, def.jobId, 'canManage') == true
end

--- Set a shop's tabs and where its goods sit.
---
--- `categories` is the tabs in order (names of 1-24 letters, at most 12; nil keeps the shop's). Each
--- `layout` entry REPLACES that item's place — `{ category = 'Drinks', order = 3 }`; an entry with
--- neither takes the item's place away — and an item not mentioned keeps its own. A tab that no
--- longer exists is taken off every item, so a removed tab cannot come back through a forgotten one.
---@param shopId number
---@param categories string[]|nil
---@param layout table<string, { category: string|nil, order: number|nil }>|nil
---@param expectRev number|nil  the layout revision the caller's draft was made from (Edit Shelf); nil: no check
---@return boolean ok
---@return string|nil err
function Shops.setLayout(shopId, categories, layout, expectRev)
    if not Shops.getDef(shopId) then return false, 'Shop not found' end
    if categories ~= nil and type(categories) ~= 'table' then return false, 'categories must be a list of tab names' end
    if layout ~= nil and type(layout) ~= 'table' then return false, 'layout must map item keys to { category, order }' end

    -- Built in the shop's turn, from its settings as the change before this one left them. Not from a
    -- stale draft: Edit Shelf posts its whole draft, so every save bumps `settings.layoutRev` and one
    -- made against an older revision (`expectRev`) is refused. Shops.update writes the row first, then
    -- redraws every customer at the shop.
    return Shops.update(shopId, function(def)
        local settings = type(def.settings) == 'table' and def.settings or {}
        local rev = math.tointeger(tonumber(settings.layoutRev)) or 0
        if expectRev ~= nil and expectRev ~= rev then
            return false, 'Someone else changed the shelf while you were editing: open Edit Shelf again'
        end

        local tabs, seen = {}, {}
        local given = categories
        if given == nil then given = type(settings.categories) == 'table' and settings.categories or {} end
        for _, c in ipairs(given) do
            if type(c) ~= 'string' then return false, 'a tab name must be text' end
            local name = c:match('^%s*(.-)%s*$')
            if name == '' or #name > MAX_TAB_LEN then
                return false, ('a tab name is 1 to %d letters'):format(MAX_TAB_LEN)
            end
            if not seen[name:lower()] then
                seen[name:lower()] = true
                tabs[#tabs + 1] = name
            end
        end
        if #tabs > MAX_TABS then return false, ('a shop has at most %d tabs'):format(MAX_TABS) end
        local isTab = {}
        for _, t in ipairs(tabs) do isTab[t] = true end

        -- The places as they are, then the ones given over them.
        local placed = {}
        for item, place in pairs(type(settings.layout) == 'table' and settings.layout or {}) do
            if type(item) == 'string' and type(place) == 'table' then
                placed[item] = { category = place.category, order = place.order }
            end
        end
        local n = 0
        for item, place in pairs(layout or {}) do
            n = n + 1
            if n > MAX_PLACED then return false, ('at most %d goods can be placed'):format(MAX_PLACED) end
            if type(item) ~= 'string' or not Config.Items[item] then
                return false, ('No such item: %s'):format(tostring(item))
            end
            if type(place) ~= 'table' then return false, ('%s: a place is { category, order }'):format(item) end
            local entry = {}
            if place.category ~= nil and place.category ~= false and place.category ~= '' then
                if type(place.category) ~= 'string' or not isTab[place.category] then
                    return false, ('%s is in a tab the shop does not have: %s'):format(item, tostring(place.category))
                end
                entry.category = place.category
            end
            local order = math.tointeger(tonumber(place.order))
            if order then entry.order = math.max(1, math.min(100000, order)) end
            placed[item] = entry
        end

        local out = {}
        for item, entry in pairs(placed) do
            if entry.category ~= nil and not isTab[entry.category] then entry.category = nil end
            if entry.category ~= nil or entry.order ~= nil then out[item] = entry end
        end

        local newSettings = {}
        for k, v in pairs(settings) do newSettings[k] = v end
        newSettings.categories = tabs
        newSettings.layout = out
        newSettings.layoutRev = rev + 1
        return { settings = newSettings }
    end)
end

--- Save the shelf from the shop screen's Edit Shelf. The shop the player has open, at its counter, by
--- one of the people allowed to arrange it (Shops.canArrange).
SecureEvent('whip_core:server:shopSetLayout', {
    rateLimit = 1000,
    burst     = 3,
    -- layoutRev: the shelf's revision when Edit Shelf opened (-1: not said, no check)
    params = { {'categories', 'any'}, {'layout', 'any'}, {'layoutRev', 'int', -1, 2147483647, -1} },
}, function(source, _, categories, layout, layoutRev)
    local shopId = Shops.openShopOf(source)
    local def = shopId and Shops.getDef(shopId)
    if not shopId or not def then return false, 'No shop open' end
    if not Shops.inRange(source) then return false, 'Too far from shop' end
    if not Shops.canArrange(source, def) then return false, 'You cannot arrange this shop' end
    if type(categories) ~= 'table' or type(layout) ~= 'table' then return false, 'Nothing to save' end
    local ok, err = Shops.setLayout(shopId, categories, layout, layoutRev >= 0 and layoutRev or nil)
    if not ok then return false, err or 'Could not save the shelf' end
    ShowSuccess(source, 'Shelf saved')
end)

--- Set one basket line to an exact quantity (0 takes it out). See Shops.setLine.
SecureEvent('whip_core:server:basketSetQuantity', {
    -- Minus and plus are clicked in runs: a short burst, then the interval.
    rateLimit = 100,
    burst     = 10,
    -- The line is an address ('id' rejects line 60 rather than clamping it onto line 50 — a
    -- different line); the quantity is a count, and clamping a count is fine.
    params = { {'basketSlot', 'id', 1, 50}, {'quantity', 'int', 0, 999} },
}, function(source, _, basketSlot, quantity)
    local ok, why = Shops.setLine(source, basketSlot, quantity)
    if not ok then return false, why end
    if why then NotifyPlayer(source, why, 'warning', 3000) end
end)

--- Draw the shop screen for one player.
---@param source number
function Shops.pushScreen(source)
    if not Shops._openShops[source] then return end
    TriggerClientEvent('whip_core:client:shopScreenUpdate', source, Shops.buildScreenState(source))
end

--- Every customer at the shop sees it change: one push per screen, a moment after the last change
--- in a burst.
local refreshDue = {}

---@param shopId number
function Shops.refreshShop(shopId)
    if not shopId or refreshDue[shopId] then return end
    local anyone = false
    for _, open in pairs(Shops._openShops) do
        if open == shopId then anyone = true break end
    end
    if not anyone then return end

    refreshDue[shopId] = true
    SetTimeout(150, function()
        refreshDue[shopId] = nil
        -- Collected first: drawing can wait on a price read, and people come and go meanwhile.
        local viewers = {}
        for src, open in pairs(Shops._openShops) do
            if open == shopId then viewers[#viewers + 1] = src end
        end
        for _, src in ipairs(viewers) do
            local ok, err = pcall(Shops.pushScreen, src)
            if not ok then
                print(('[whip_core:shops] could not redraw shop #%s for src %s: %s')
                    :format(tostring(shopId), tostring(src), tostring(err)))
            end
        end
    end)
end

--- Redraw every shop whose shelf is this stock container.
---@param containerId number
function Shops.refreshContainer(containerId)
    if not containerId then return end
    for shopId, def in pairs(Shops.cache) do
        if def.mode == 'stocked' and def.containerId == containerId then Shops.refreshShop(shopId) end
    end
end

-- ============================================
-- Database Operations
-- ============================================

---@return boolean ok
function Shops.ensureTable()
    local ok = CreateTable('shops', [[
        CREATE TABLE IF NOT EXISTS `shops` (
            `shopId`       INT UNSIGNED      NOT NULL AUTO_INCREMENT,
            `key`          VARCHAR(60)       DEFAULT NULL,
            `name`         VARCHAR(100)      NOT NULL DEFAULT 'Shop',
            `mode`         ENUM('infinite','stocked','npc') NOT NULL DEFAULT 'npc',
            `jobId`        INT UNSIGNED      DEFAULT NULL,
            `containerId`  INT UNSIGNED      DEFAULT NULL,
            `npcModel`     VARCHAR(60)       DEFAULT NULL,
            `prop`         VARCHAR(60)       DEFAULT NULL,
            `x`            FLOAT             NOT NULL,
            `y`            FLOAT             NOT NULL,
            `z`            FLOAT             NOT NULL,
            `heading`      FLOAT             NOT NULL DEFAULT 0.0,
            `blipSprite`   INT               DEFAULT NULL,
            `blipColor`    INT               NOT NULL DEFAULT 2,
            `catalog`      JSON              DEFAULT NULL,
            `settings`     JSON              DEFAULT NULL,
            `createdAt`    TIMESTAMP         NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `createdBy`    INT UNSIGNED      DEFAULT NULL,
            PRIMARY KEY (`shopId`),
            UNIQUE KEY `uk_shop_key` (`key`),
            KEY `idx_shop_container` (`containerId`),
            KEY `idx_shop_job` (`jobId`),
            CONSTRAINT `fk_shop_createdBy` FOREIGN KEY (`createdBy`)
                REFERENCES `characters` (`charId`) ON DELETE SET NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    -- A stocked shop's prices belong to its shelf container, and go with it. One per item.
    local ok2 = CreateTable('shop_item_prices', [[
        CREATE TABLE IF NOT EXISTS `shop_item_prices` (
            `containerId`  INT UNSIGNED      NOT NULL,
            `item`         VARCHAR(50)       NOT NULL,
            `price`        INT UNSIGNED      NOT NULL DEFAULT 0,
            `forSale`      TINYINT(1)        NOT NULL DEFAULT 0,
            PRIMARY KEY (`containerId`, `item`),
            CONSTRAINT `fk_siprice_container` FOREIGN KEY (`containerId`)
                REFERENCES `containers` (`containerId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    return ok and ok2
end

function Shops.loadAll()
    Shops.ensureTable()
    local ok, rows = pcall(MySQL.query.await,
        'SELECT * FROM `shops` ORDER BY `shopId` ASC'
    )

    if not ok then
        print('[whip_core:shops] ERROR loading shops: ' .. tostring(rows))
        return false   -- start-up halts (player_lifecycle.lua)
    end

    Shops.cache = {}
    Shops._keyIndex = {}

    if rows then
        for _, row in ipairs(rows) do
            local def = {
                shopId      = row.shopId,
                key         = row.key,
                name        = row.name,
                mode        = row.mode,
                jobId       = row.jobId,
                containerId = row.containerId,
                npcModel    = row.npcModel,
                prop        = row.prop,
                x           = row.x,
                y           = row.y,
                z           = row.z,
                heading     = row.heading,
                blipSprite  = row.blipSprite,
                blipColor   = row.blipColor or 2,
                catalog     = nil,
                settings    = nil,
                createdAt   = EpochSeconds(row.createdAt),   -- seconds, like a shop made this session
                createdBy   = row.createdBy,
            }

            -- Guarded: a row that is not a JSON object (hand-edited, a cut-off write) is read as none,
            -- rather than stopping the load.
            if row.catalog and row.catalog ~= '' and row.catalog ~= '{}' then
                local okJson, decoded = pcall(json.decode, row.catalog)
                if not okJson or type(decoded) ~= 'table' then
                    print(('[whip_core:shops] shop %s: its catalog is not readable JSON — read as empty'):format(tostring(row.shopId)))
                    decoded = nil
                end
                if decoded and next(decoded) then
                    -- One shape in memory, as validateCatalog gives on the way in: an older
                    -- `{ price = n }` entry or a fractional price becomes a whole number.
                    for itemKey, entry in pairs(decoded) do
                        local price = tonumber(type(entry) == 'table' and entry.price or entry)
                        decoded[itemKey] = price and math.floor(price) or nil
                    end
                    def.catalog = decoded
                end
            end

            if row.settings and row.settings ~= '' and row.settings ~= '{}' then
                local okJson, decoded = pcall(json.decode, row.settings)
                if not okJson or type(decoded) ~= 'table' then
                    print(('[whip_core:shops] shop %s: its settings are not readable JSON — read as none'):format(tostring(row.shopId)))
                    decoded = nil
                end
                if decoded and next(decoded) then
                    def.settings = decoded
                end
            end

            Shops.cache[def.shopId] = def
            if def.key then
                Shops._keyIndex[def.key] = def.shopId
            end
        end
    end

end

function Shops.count()
    local n = 0
    for _ in pairs(Shops.cache) do n = n + 1 end
    return n
end

-- ============================================
-- Config Seeding (garages pattern)
-- ============================================

function Shops.seedFromConfig()
    if not Config.Shops then return end

    for key, data in pairs(Config.Shops) do
        if not Shops._keyIndex[key] then
            local x, y, z, h = data.pos.x, data.pos.y, data.pos.z, data.pos.w or 0.0
            Shops.create({
                key        = key,
                name       = data.name or 'Shop',
                mode       = data.mode or 'npc',
                jobId      = data.jobId,
                containerId = data.containerId,
                npcModel   = data.npcModel,
                prop       = data.prop,
                x          = x,
                y          = y,
                z          = z,
                heading    = h,
                blipSprite = data.blipSprite,
                blipColor  = data.blipColor or 2,
                catalog    = data.catalog,
                settings   = data.settings,
            })
        end
    end
end

-- ============================================
-- CRUD
-- ============================================

--- Is this a catalog priceFor can actually read? And if so, the same catalog in ONE shape.
---
--- The shape is a MAP of item key to a whole-dollar price — `{ food = 10 }`. Item keys are NOT checked
--- against the item registry here: a satellite's items can register after the shops that sell them.
---
--- `{ food = { price = 10 } }` and 9.99 are accepted, but both come back as plain whole numbers.
---@param catalog any
---@return boolean ok
---@return string|nil err
---@return table|nil normalised  item key -> whole-number price
local function validateCatalog(catalog)
    if type(catalog) ~= 'table' then return false, 'catalog must be a table' end
    local normalised = {}
    for key, entry in pairs(catalog) do
        if type(key) ~= 'string' or key == '' then
            return false, 'catalog must map item keys to prices, e.g. { food = 10 }'
        end
        local price = tonumber(type(entry) == 'table' and entry.price or entry)
        if not price or price ~= price or price < 0 or price == math.huge then
            return false, ('invalid price for %s'):format(key)
        end
        normalised[key] = math.floor(price)
    end
    return true, nil, normalised
end

--- `(def)` or `(false, reason)`.
---@param data table
---@return table|false def
---@return string|nil err
function Shops.create(data)
    if type(data) ~= 'table' then return false, 'CreateShop needs a data table' end
    if not (tonumber(data.x) and tonumber(data.y) and tonumber(data.z)) then
        return false, 'a shop needs x, y and z'
    end

    local catalog = nil
    if data.catalog ~= nil then
        local valid, catErr, normalised = validateCatalog(data.catalog)
        if not valid then
            print(('[whip_core:shops] ERROR creating shop "%s": %s'):format(tostring(data.name), catErr))
            return false, catErr
        end
        catalog = normalised
    end

    local catalogJson = catalog and json.encode(catalog) or '{}'
    local settingsJson = data.settings and json.encode(data.settings) or '{}'

    local ok, insertId = pcall(MySQL.insert.await,
        'INSERT INTO `shops` (`key`, `name`, `mode`, `jobId`, `containerId`, `npcModel`, `prop`, `x`, `y`, `z`, `heading`, `blipSprite`, `blipColor`, `catalog`, `settings`, `createdBy`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        {
            data.key or nil,
            data.name or 'Shop',
            data.mode or 'npc',
            data.jobId or nil,
            data.containerId or nil,
            data.npcModel or nil,
            data.prop or nil,
            data.x,
            data.y,
            data.z,
            data.heading or 0.0,
            data.blipSprite or nil,
            data.blipColor or 2,
            catalogJson,
            settingsJson,
            data.createdBy or nil,
        }
    )

    if not ok or not insertId then
        print('[whip_core:shops] ERROR creating shop: ' .. tostring(insertId))
        return false, 'Could not save the shop (database error)'
    end

    local def = {
        shopId      = insertId,
        key         = data.key,
        name        = data.name or 'Shop',
        mode        = data.mode or 'npc',
        jobId       = data.jobId,
        containerId = data.containerId,
        npcModel    = data.npcModel,
        prop        = data.prop,
        x           = data.x,
        y           = data.y,
        z           = data.z,
        heading     = data.heading or 0.0,
        blipSprite  = data.blipSprite,
        blipColor   = data.blipColor or 2,
        catalog     = catalog,
        settings    = data.settings,
        createdAt   = os.time(),
        createdBy   = data.createdBy,
    }

    Shops.cache[def.shopId] = def
    if def.key then
        Shops._keyIndex[def.key] = def.shopId
    end

    -- Broadcast to all clients for streaming
    TriggerClientEvent('whip_core:client:shopCreated', -1, Shops.wireOne(def))
    -- Its keeper and its prompt (server/shop_counters.lua), before the public event: another
    -- resource hearing of the shop finds it ready to use.
    Shops.openCounter(def)
    WhipEmit('whip_core:shop:created', { shopId = def.shopId, shop = def })

    return def
end

--- Shops.update's work, one at a time per shop (Shops.update, below).
local function updateNow(shopId, data)
    local def = Shops.cache[shopId]
    if not def then return false end

    local catalog = nil
    if data.catalog ~= nil then
        local valid, catErr, normalised = validateCatalog(data.catalog)
        if not valid then return false, catErr end
        catalog = normalised
    end

    -- Row first, memory second (as Garages.update): a failed write changes nothing.
    local staged = {}
    for k, v in pairs(def) do staged[k] = v end
    if data.name ~= nil then staged.name = data.name end
    if data.mode ~= nil then staged.mode = data.mode end
    if data.x ~= nil then staged.x = data.x end
    if data.y ~= nil then staged.y = data.y end
    if data.z ~= nil then staged.z = data.z end
    if data.heading ~= nil then staged.heading = data.heading end
    if data.blipColor ~= nil then staged.blipColor = data.blipColor end
    if catalog ~= nil then staged.catalog = catalog end
    if data.settings ~= nil then staged.settings = data.settings end

    -- The fields that can be empty: `false` clears one (to NULL); nil means "not mentioned".
    local cleared = {}
    for _, field in ipairs({ 'jobId', 'containerId', 'npcModel', 'prop', 'blipSprite', 'key' }) do
        if data[field] == false then
            staged[field] = nil
            cleared[#cleared + 1] = field
        elseif data[field] ~= nil then
            staged[field] = data[field]
        end
    end

    -- A new mode or a new shelf ends every open basket, as deleting the shop does: a basket belongs
    -- to the shop as it was when filled (switched to stocked, its conjured goods would become stock;
    -- switched away, its real goods would have no shelf). Not while somebody is paying: checkout owns
    -- that basket, so the admin is asked to wait a moment.
    local relinked = staged.mode ~= def.mode or staged.containerId ~= def.containerId
    local viewers = {}
    if relinked then
        for source, openShopId in pairs(Shops._openShops) do
            if openShopId == shopId then
                if Shops.isCheckingOut(source) then
                    return false, 'a customer is paying there right now, try again in a moment'
                end
                viewers[#viewers + 1] = source
            end
        end
    end

    local catalogJson = staged.catalog and json.encode(staged.catalog) or '{}'
    local settingsJson = staged.settings and json.encode(staged.settings) or '{}'

    local ok, err = pcall(MySQL.query.await,
        'UPDATE `shops` SET `key`=?, `name`=?, `mode`=?, `jobId`=?, `containerId`=?, `npcModel`=?, `prop`=?, `x`=?, `y`=?, `z`=?, `heading`=?, `blipSprite`=?, `blipColor`=?, `catalog`=?, `settings`=? WHERE `shopId`=?',
        {
            staged.key, staged.name, staged.mode, staged.jobId, staged.containerId,
            staged.npcModel, staged.prop, staged.x, staged.y, staged.z, staged.heading,
            staged.blipSprite, staged.blipColor, catalogJson, settingsJson, shopId,
        }
    )
    if not ok then
        print(('[whip_core:shops] ERROR updating shop #%d: %s'):format(shopId, tostring(err)))
        return false, DB_ERROR
    end
    -- Gone from memory during the write (a reload): nothing here may put it back on anyone's screen.
    if Shops.cache[shopId] ~= def then return false, 'Shop not found' end

    -- The row took it; now memory may agree, starting with the old key's index entry.
    if def.key and Shops._keyIndex[def.key] == shopId then
        Shops._keyIndex[def.key] = nil
    end

    -- The baskets go back while the def still describes the OLD shop — that is which shelf they came
    -- off. Collected again, because the write above yielded and people may have come or gone. The stock
    -- write is only queued (endSession's no-yield path), so nobody can open the shop in between and
    -- fill a basket under the old rules; the flush follows once the new def is in place.
    local oldStock = relinked and def.mode == 'stocked' and def.containerId or nil
    if relinked then
        viewers = {}
        for source, openShopId in pairs(Shops._openShops) do
            if openShopId == shopId and not Shops.isCheckingOut(source) then
                viewers[#viewers + 1] = source
            end
        end
        for _, source in ipairs(viewers) do
            local ended, endErr = pcall(Shops.endSession, source, true)
            if not ended then
                print(('[whip_core:shops] ERROR closing shop #%d for src %s: %s')
                    :format(shopId, tostring(source), tostring(endErr)))
            end
            TriggerClientEvent('whip_core:client:shopClosed', source)
        end
    end

    -- Applied in place so every held reference to the def sees the change. A cleared field is
    -- absent from `staged`, so it is removed from the def by name.
    for k, v in pairs(staged) do def[k] = v end
    for _, field in ipairs(cleared) do def[field] = nil end

    -- Rebuild key index
    if def.key then
        Shops._keyIndex[def.key] = shopId
    end

    TriggerClientEvent('whip_core:client:shopUpdated', -1, Shops.wireOne(def))
    Shops.openCounter(def)   -- moved, or a new keeper: a new counter; renamed, a new job: its prompt changes
    WhipEmit('whip_core:shop:updated', { shopId = def.shopId, shop = def })
    -- A new catalog, layout or name: whoever is shopping there sees it now.
    Shops.refreshShop(shopId)

    -- Last, because it yields: the returned stock is written now rather than left queued, the same
    -- rule a normal close follows.
    if oldStock and #viewers > 0 then
        local stockStore = Stores.container(oldStock)
        if stockStore then pcall(Stores.flushNow, stockStore) end
    end

    return true
end

local updating = {}   -- [shopId] = true while an update or the delete of that shop is under way
local UPDATE_WAIT_MS = 5000

--- Run `fn` in the shop's turn: one change at a time per shop, a second waiting for the first (a few seconds at
--- most). Its error goes on up once the turn is given back.
---@return boolean ok
---@return string|nil why
local function inShopTurn(shopId, fn)
    local deadline = GetGameTimer() + UPDATE_WAIT_MS
    while updating[shopId] do
        if GetGameTimer() > deadline then return false, 'that shop is being changed — try again in a moment' end
        Wait(20)
    end
    updating[shopId] = true
    local ran, ok, why = pcall(fn)
    updating[shopId] = nil
    if not ran then error(ok, 0) end
    return ok, why
end

--- Change a shop, one at a time per shop: an update writes EVERY column and yields on the write, so two
--- at once would overwrite each other. A second waits for the first (a few seconds at most).
---
--- `data` may be a function, def -> data or false, why, run in the shop's turn, so a caller that
--- rewrites a whole table (Edit Shelf's settings, the catalog) builds it from what the change before
--- it left.
---@param shopId number
---@param data table|fun(def: table): table|false, string|nil
---@return boolean ok
---@return string|nil why
function Shops.update(shopId, data)
    return inShopTurn(shopId, function()
        if type(data) == 'function' then
            local def = Shops.cache[shopId]
            if not def then return false, 'Shop not found' end
            local built, why = data(def)
            if not built then return false, why end
            return updateNow(shopId, built)
        end
        return updateNow(shopId, data)
    end)
end

---@param shopId number
---@return boolean ok
---@return string|nil err
local function deleteNow(shopId)
    local def = Shops.cache[shopId]
    if not def then return false end

    -- Checked, and first: before any state is torn down, so a failed delete changes nothing.
    local ok, err = pcall(MySQL.query.await, 'DELETE FROM `shops` WHERE `shopId` = ?', {shopId})
    if not ok then
        print(('[whip_core:shops] ERROR deleting shop #%d: %s'):format(shopId, tostring(err)))
        return false, DB_ERROR
    end

    -- Remove key index
    if def.key and Shops._keyIndex[def.key] == shopId then
        Shops._keyIndex[def.key] = nil
    end

    -- Close for any player who has it open: collected first (endSession writes to _openShops), and
    -- before the def leaves the cache (returning a basket needs its shelf).
    local viewers = {}
    for source, openShopId in pairs(Shops._openShops) do
        if openShopId == shopId then viewers[#viewers + 1] = source end
    end
    for _, source in ipairs(viewers) do
        Shops.endSession(source)
        TriggerClientEvent('whip_core:client:shopClosed', source)
    end

    Shops.cache[shopId] = nil
    Shops.closeCounter(shopId)   -- its keeper and its prompt go with it

    TriggerClientEvent('whip_core:client:shopDeleted', -1, shopId)
    WhipEmit('whip_core:shop:deleted', { shopId = shopId })

    return true
end

--- Delete a shop, in its turn: an update of it under way finishes first (or it would put the shop back).
---@param shopId number
---@return boolean ok
---@return string|nil why
function Shops.delete(shopId)
    return inShopTurn(shopId, function() return deleteNow(shopId) end)
end

-- ============================================
-- Accessors
-- ============================================

---@param shopId number|nil
---@return table|nil
function Shops.getDef(shopId)
    return Shops.cache[shopId]
end

--- The resource that made a shop through EnsureShop (settings.ensured.by) or CreateShop
--- (settings.owner), or nil for one an admin made — whip's own, always shown.
---@return string|nil
function Shops.ownerOf(def)
    local s = def and def.settings
    if type(s) ~= 'table' then return nil end
    if type(s.ensured) == 'table' and type(s.ensured.by) == 'string' then return s.ensured.by end
    if type(s.owner) == 'string' then return s.owner end
    return nil
end

--- Is the resource that made this shop not running? Then its blip is not shown. The shop itself
--- stays, as its stock and records do.
local function ownerAway(def)
    local owner = Shops.ownerOf(def)
    if not owner or owner == GetCurrentResourceName() then return false end
    local state = GetResourceState(owner)
    return state ~= 'started' and state ~= 'starting'
end

--- Client-facing projection of ONE shop: a copy of the fields the client reads (streaming, blips,
--- labels, the jobId for the manage option). Catalog, settings, containerId, key and createdBy stay
--- on the server.
---@param def table
---@return table
function Shops.wireOne(def)
    return {
        shopId     = def.shopId,
        name       = def.name,
        mode       = def.mode,
        jobId      = def.jobId,
        npcModel   = def.npcModel,
        prop       = def.prop,
        x          = def.x,
        y          = def.y,
        z          = def.z,
        heading    = def.heading,
        blipSprite = def.blipSprite,
        blipColor  = def.blipColor,
        ownerAway  = ownerAway(def) or nil,
    }
end

-- A shop's maker starting or stopping changes whether its blip shows: told to every client. (While
-- stopping its state is 'stopping', so the blip goes; while starting, 'starting', so it comes.)
local function ownerChanged(resource)
    for _, def in pairs(Shops.cache or {}) do
        if Shops.ownerOf(def) == resource then
            TriggerClientEvent('whip_core:client:shopUpdated', -1, Shops.wireOne(def))
        end
    end
end
AddEventHandler('onResourceStart', ownerChanged)
AddEventHandler('onResourceStop', ownerChanged)

--- Every shop, wired for the client. This is what shopsSync sends.
---@return table[] array sorted by shopId
function Shops.wire()
    local out = {}
    for _, def in pairs(Shops.cache) do
        out[#out + 1] = Shops.wireOne(def)
    end
    table.sort(out, function(a, b) return a.shopId < b.shopId end)
    return out
end

---@return table[] array sorted by shopId
function Shops.getAll()
    local arr = {}
    for _, def in pairs(Shops.cache) do
        arr[#arr + 1] = def
    end
    table.sort(arr, function(a, b) return a.shopId < b.shopId end)
    return arr
end

---@param key string
---@return table|nil
function Shops.getByKey(key)
    local shopId = Shops._keyIndex[key]
    if shopId then return Shops.cache[shopId] end
    return nil
end

--- Update a shop's catalog (infinite/npc modes)
---@param shopId number
---@param catalog table  { [itemKey] = price }
---@return boolean
function Shops.updateCatalog(shopId, catalog)
    return Shops.update(shopId, { catalog = catalog })
end

--- A declared number, to the millimetre — the zone rule (zones.lua `mm`). The declaration is kept
--- in the shop's settings and read back through JSON; an unrounded float never equals itself again,
--- and every start would rewrite the shop.
local function mm(n)
    n = tonumber(n)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return math.floor(n * 1000 + 0.5) / 1000
end

--- The fields a declaration can drop, cleared (to NULL) when the code stops declaring them.
local DECL_CLEARABLE = { 'jobId', 'containerId', 'npcModel', 'prop', 'blipSprite' }

--- A shop declaration as plain values — what is compared to tell whether a resource changed its
--- shop. nil and why for one that cannot be a shop.
---@return table|nil decl
---@return string|nil why
local function declaration(data)
    local d = {}
    for _, f in ipairs({ 'x', 'y', 'z', 'heading' }) do
        if data[f] ~= nil then
            d[f] = mm(data[f])
            if not d[f] then return nil, f .. ' must be a number' end
        end
    end
    if not (d.x and d.y and d.z) then return nil, 'a shop needs x, y and z' end
    if data.name ~= nil then
        if type(data.name) ~= 'string' or data.name == '' then return nil, 'name must be text' end
        d.name = data.name
    end
    if data.mode ~= nil then
        if data.mode ~= 'npc' and data.mode ~= 'infinite' and data.mode ~= 'stocked' then
            return nil, "mode is 'npc', 'infinite' or 'stocked'"
        end
        d.mode = data.mode
    end
    -- The job by jobId or key, like every Jobs export. The declaration keeps what the code
    -- wrote; the resolved id is what the shop stores.
    if data.jobId ~= nil then
        if not Jobs.resolve(data.jobId) then return nil, 'No such job' end
        d.jobId = data.jobId
    end
    if data.containerId ~= nil then
        local id = tonumber(data.containerId)
        if not (id and Containers.getDef(id)) then return nil, 'No such container' end
        d.containerId = id
    end
    for _, f in ipairs({ 'npcModel', 'prop' }) do
        if data[f] ~= nil then
            if type(data[f]) ~= 'string' or data[f] == '' then return nil, f .. ' must be text' end
            d[f] = data[f]
        end
    end
    for _, f in ipairs({ 'blipSprite', 'blipColor' }) do
        if data[f] ~= nil then
            d[f] = math.tointeger(tonumber(data[f]))
            if not d[f] then return nil, f .. ' must be a whole number' end
        end
    end
    if data.catalog ~= nil then
        local ok, why, normalised = validateCatalog(data.catalog)
        if not ok then return nil, why end
        d.catalog = normalised
    end
    if data.settings ~= nil then
        if type(data.settings) ~= 'table' then return nil, 'settings must be a table' end
        -- Through JSON now, so it compares equal to what the row gives back after a restart.
        local copy = json.decode(json.encode(data.settings)) or {}
        copy.ensured = nil   -- EnsureShop's own record (below); a declaration does not write it
        d.settings = copy
    end
    return d
end

--- Find-or-create by key, declared in code (the EnsureZone rule):
---   * a new key makes the shop;
---   * the SAME declaration as last time changes nothing, so an admin's panel edits since then stand;
---   * a CHANGED declaration is applied — every field it names — and a field the last one named and
---     this one drops (jobId, containerId, npcModel, prop, blipSprite) is cleared;
---   * a key another running resource declared is refused.
--- The declaration and who made it are kept in `settings.ensured`.
---@param key string
---@param data table
---@param caller string|nil  the declaring resource
---@return table|false def
---@return string|nil err  see Shops.create
function Shops.ensureShop(key, data, caller)
    if type(key) ~= 'string' or key == '' then return false, 'EnsureShop needs a string key' end
    if type(data) ~= 'table' then return false, 'EnsureShop needs a data table' end
    local d, why = declaration(data)
    if not d then return false, why end
    caller = caller or GetCurrentResourceName()

    local fields = {}
    for k, v in pairs(d) do fields[k] = v end
    if d.jobId ~= nil then fields.jobId = Jobs.resolve(d.jobId).jobId end
    local ensured = { by = caller, decl = d }

    local existing = Shops.getByKey(key)
    if not existing then
        fields.key = key
        fields.settings = fields.settings or {}
        fields.settings.ensured = ensured
        return Shops.create(fields)
    end

    local ens = type(existing.settings) == 'table' and existing.settings.ensured or nil
    local by = type(ens) == 'table' and ens.by or nil
    if by and by ~= caller and Registry.alive(by) then
        return false, ('shop "%s" is declared by %s'):format(key, by)
    end
    if by == caller and type(ens) == 'table' and Registry.deepEquals(ens.decl, d) then return existing end

    -- Built in the shop's turn, from its settings as they are then.
    local ok, err = Shops.update(existing.shopId, function(cur)
        local curEns = type(cur.settings) == 'table' and cur.settings.ensured or nil
        local before = type(curEns) == 'table' and curEns.by and type(curEns.decl) == 'table' and curEns.decl or {}
        local out = {}
        for k, v in pairs(fields) do out[k] = v end
        for _, f in ipairs(DECL_CLEARABLE) do
            if out[f] == nil and before[f] ~= nil then out[f] = false end
        end
        -- Settings are merged: the declared ones replace the old; undeclared, the shop keeps its own (the
        -- managers' Edit Shelf tabs and order above all). A key the last declaration set and this one
        -- doesn't is cleared, as DECL_CLEARABLE does for fields.
        local settings = {}
        for k, v in pairs(type(cur.settings) == 'table' and cur.settings or {}) do settings[k] = v end
        local declared = type(fields.settings) == 'table' and fields.settings or {}
        for k in pairs(type(before.settings) == 'table' and before.settings or {}) do
            if declared[k] == nil then settings[k] = nil end
        end
        for k, v in pairs(declared) do settings[k] = v end
        settings.ensured = ensured
        out.settings = settings
        return out
    end)
    if not ok then return false, err or DB_ERROR end
    return Shops.cache[existing.shopId]
end

-- ============================================
-- Pricing (stocked mode)
-- ============================================

-- One price per item, in shop_item_prices, keyed by the shelf container and the item.

---@param containerId number
function Shops.loadPrices(containerId)
    if Shops.priceCache[containerId] then return end

    local ok, rows = pcall(MySQL.query.await,
        'SELECT `item`, `price`, `forSale` FROM `shop_item_prices` WHERE `containerId` = ?',
        {containerId}
    )

    -- A failed read is not "no prices": not cached, so the next ask reads again; until then every
    -- item answers no price, and nothing is sold.
    if not ok then
        print(('[whip_core:shops] could not read the prices of container #%s: %s')
            :format(tostring(containerId), tostring(rows)))
        return
    end

    local prices = {}
    if rows then
        for _, row in ipairs(rows) do
            prices[row.item] = {
                price   = row.price,
                forSale = row.forSale == 1 or row.forSale == true,
            }
        end
    end

    -- First load wins (Containers.loadInventory's rule): a load that finished first may already hold a
    -- price set since, which this older read must not undo.
    if Shops.priceCache[containerId] then return end
    Shops.priceCache[containerId] = prices
end

--- Price an item on a stocked shop's shelf, or take it off sale (forSale false keeps the price).
---@param containerId number|string|nil  the shop's stock container
---@param itemKey string
---@param price number|string|nil
---@param forSale boolean
---@param slot number|nil  for the priceChanged event, when the price was set from a shelf slot
---@return boolean ok, string|nil err
function Shops.setItemPrice(containerId, itemKey, price, forSale, slot)
    -- Checked here, not only at the event: the exports hand this whatever a satellite passed (a
    -- non-number, NaN, an unknown container). A negative price is floored to 0 below.
    containerId = tonumber(containerId)
    local container = containerId and Containers.getDef(containerId)
    if not containerId or not container then return false, 'Unknown container' end

    if type(itemKey) ~= 'string' or not Config.Items[itemKey] then return false, 'Unknown item' end

    price = tonumber(price)
    -- `price ~= price` is how NaN is spotted: it is the one value not equal to itself.
    if not price or price ~= price or price == math.huge then
        return false, 'Invalid price'
    end

    if not Shops.priceCache[containerId] then
        Shops.loadPrices(containerId)
    end
    -- The other prices could not be read. Writing one now would cache a table holding only it, and
    -- every other item would read as unpriced.
    if not Shops.priceCache[containerId] then return false, DB_ERROR end

    -- Row first, memory second, as Shops.update.
    local newPrice   = math.max(0, math.floor(price))
    local newForSale = forSale and true or false

    local ok, err = pcall(MySQL.query.await,
        'REPLACE INTO `shop_item_prices` (`containerId`, `item`, `price`, `forSale`) VALUES (?, ?, ?, ?)',
        {containerId, itemKey, newPrice, newForSale and 1 or 0}
    )
    if not ok then
        print(('[whip_core:shops] ERROR pricing %s in container #%d: %s')
            :format(itemKey, containerId, tostring(err)))
        return false, DB_ERROR
    end

    Shops.priceCache[containerId][itemKey] = {
        price   = newPrice,
        forSale = newForSale,
    }

    local priced = {
        containerId = containerId,
        item        = itemKey,
        slot        = slot,
        price       = newPrice,
        forSale     = newForSale,
    }
    WhipEmit('whip_core:shop:priceChanged', priced)
    Shops.refreshContainer(containerId)   -- every customer at the shop sees the new price

    return true
end

--- Price the item ON a shelf slot: the stock view's right-click. The price is the item's, so every slot
--- holding it takes it.
---
--- `price` nil keeps the item's price, `forSale` nil its for-sale: the stock view changes one of the
--- two, and its copy of the other may be stale.
---
--- `expectItem`: the item the press was made on. If the slot holds another item by now (Set Price
--- waits on a typed dialog), nothing changes.
---
--- Never listed without a price: Mark For Sale on an item never priced is refused ("Set a price
--- first"). A deliberate $0 is a Set Price.
---@param containerId number|string|nil
---@param slot number|string|nil
---@param price number|nil
---@param forSale boolean|nil
---@param expectItem string|nil
---@return boolean ok, string|nil err
function Shops.setSlotPrice(containerId, slot, price, forSale, expectItem)
    containerId = tonumber(containerId)
    local container = containerId and Containers.getDef(containerId)
    if not containerId or not container then return false, 'Unknown container' end

    slot = tonumber(slot)
    if not slot or slot ~= math.floor(slot) or slot < 1 or slot > (container.slots or 0) then
        return false, 'Invalid slot'
    end

    -- The price is checked before the shelf is read, so a bad price says so whatever the slot holds.
    local n = nil
    if price ~= nil then
        n = tonumber(price)
        if not n or n ~= n or n == math.huge then return false, 'Invalid price' end
    end

    if not Containers.invCache[containerId] then Containers.loadInventory(containerId) end
    local inv = Containers.invCache[containerId]
    if not inv then return false, DB_ERROR end
    local d = inv[slot]
    if not d or not d.item then return false, 'That shelf slot is empty' end
    if expectItem ~= nil and d.item ~= expectItem then
        return false, 'That shelf slot changed — try again'
    end

    if n == nil or forSale == nil then
        local row = Shops.getItemPrice(containerId, d.item)
        if n == nil and forSale == true and not row then return false, 'Set a price first' end
        local now = row or { price = 0, forSale = false }
        if n == nil then n = tonumber(now.price) or 0 end
        if forSale == nil then forSale = now.forSale == true end
    end
    return Shops.setItemPrice(containerId, d.item, n, forSale, slot)
end

---@param containerId number
---@param itemKey string
---@return table|nil { price, forSale }
function Shops.getItemPrice(containerId, itemKey)
    if not Shops.priceCache[containerId] then
        Shops.loadPrices(containerId)
    end
    local cache = Shops.priceCache[containerId]   -- nil when the read failed: no price
    return cache and cache[itemKey] or nil
end

--- The stock view's prices, keyed by ITEM, as prices are; the view looks up the item on a slot as it
--- is now. Unpriced items are absent.
---@param containerId number
---@return table  { [itemKey] = { price, forSale } }
function Shops.serializePrices(containerId)
    if not Shops.priceCache[containerId] then
        Shops.loadPrices(containerId)
    end
    local prices = Shops.priceCache[containerId] or {}   -- a failed read shows none
    local result = {}
    for item, p in pairs(prices) do
        result[item] = { price = p.price, forSale = p.forSale }
    end
    return result
end

-- ============================================
-- Export Helpers (catalog + stock access)
-- ============================================

--- Get catalog for an infinite/npc shop
---@param shopId number
---@return table|nil  { [itemKey] = price }
function Shops.getCatalog(shopId)
    local def = Shops.cache[shopId]
    if not def then return nil end
    return def.catalog
end

--- Add or update a single item in a shop's catalog
---@param shopId number
---@param itemKey string
---@param price number
---@return boolean success
---@return string|nil error
function Shops.addCatalogItem(shopId, itemKey, price)
    local def = Shops.cache[shopId]
    if not def then return false, 'Shop not found' end
    if def.mode ~= 'infinite' and def.mode ~= 'npc' then
        return false, 'Shop is not infinite/npc mode'
    end
    if not Config.Items[itemKey] then
        return false, 'Unknown item: ' .. tostring(itemKey)
    end
    if type(price) ~= 'number' or price < 0 then
        return false, 'Invalid price'
    end

    price = math.floor(price)

    -- A copy goes to update, never the live catalog (update writes the row before memory agrees),
    -- made in the shop's turn from the catalog as it is then.
    local ok, err = Shops.update(shopId, function(cur)
        local catalog = {}
        for k, v in pairs(cur.catalog or {}) do catalog[k] = v end
        catalog[itemKey] = price
        return { catalog = catalog }
    end)
    if not ok then return false, err or DB_ERROR end
    if panelRefresh then panelRefresh() end

    return true
end

--- Remove a single item from a shop's catalog
---@param shopId number
---@param itemKey string
---@return boolean success
---@return string|nil error
function Shops.removeCatalogItem(shopId, itemKey)
    local def = Shops.cache[shopId]
    if not def then return false, 'Shop not found' end
    if def.mode ~= 'infinite' and def.mode ~= 'npc' then
        return false, 'Shop is not infinite/npc mode'
    end
    if not def.catalog or not def.catalog[itemKey] then
        return false, 'Item not in catalog'
    end

    -- A copy, in the shop's turn, for the same reasons as addCatalogItem above.
    local ok, err = Shops.update(shopId, function(cur)
        if not cur.catalog or not cur.catalog[itemKey] then return false, 'Item not in catalog' end
        local catalog = {}
        for k, v in pairs(cur.catalog) do catalog[k] = v end
        catalog[itemKey] = nil
        return { catalog = catalog }
    end)
    if not ok then return false, err or DB_ERROR end
    if panelRefresh then panelRefresh() end

    return true
end

--- Get full stock view for a stocked shop (inventory + prices merged)
---@param shopId number
---@return table|nil  { [slot] = { item, amount, metadata, price, forSale } }
---@return string|nil error
function Shops.getStock(shopId)
    local def = Shops.cache[shopId]
    if not def then return nil, 'Shop not found' end
    if def.mode ~= 'stocked' then return nil, 'Shop is not stocked mode' end
    if not def.containerId then return nil, 'Shop has no container' end

    if not Containers.invCache[def.containerId] then
        Containers.loadInventory(def.containerId)
    end
    Shops.loadPrices(def.containerId)

    local inv = Containers.invCache[def.containerId] or {}
    local result = {}
    for slot, slotData in pairs(inv) do
        -- The price is the item's, shown on every slot holding it.
        local priceData = Shops.priceCache[def.containerId]
            and Shops.priceCache[def.containerId][slotData.item] or nil
        result[slot] = {
            item    = slotData.item,
            amount  = slotData.amount or 1,
            metadata = slotData.metadata,
            price   = priceData and priceData.price or 0,
            forSale = priceData and priceData.forSale or false,
        }
    end
    return result
end

--- Every item price a stocked shop has, for sale or not. A copy: the caller's to keep.
---@param shopId number
---@return table|nil  { [itemKey] = { price, forSale } }
---@return string|nil error
function Shops.getPrices(shopId)
    local def = Shops.cache[shopId]
    if not def then return nil, 'Shop not found' end
    if def.mode ~= 'stocked' then return nil, 'Shop is not stocked mode' end
    if not def.containerId then return nil, 'Shop has no container' end

    Shops.loadPrices(def.containerId)
    local out = {}
    for item, p in pairs(Shops.priceCache[def.containerId] or {}) do
        out[item] = { price = p.price, forSale = p.forSale }
    end
    return out
end

-- ============================================
-- Build Shop Data for Client
-- ============================================

--- Build the payload sent to client when opening a shop
---@param shopId number
---@param charId number
---@return table|nil
function Shops.buildShopPayload(shopId, charId)
    local def = Shops.cache[shopId]
    if not def then return nil end

    -- The screen's grids are NOT here: the caller adds them from Shops.buildScreenState.
    -- What the shop takes (settings.currency, an item; banknotes when unset). The screen prices in it,
    -- and offers the bank only for money: a shop that trades in gold bars cannot be paid in dollars.
    local currency = (type(def.settings) == 'table' and def.settings.currency) or 'cash'
    local payload = {
        shopId    = def.shopId,
        name      = def.name,
        mode      = def.mode,
        jobId     = def.jobId,
        currency  = { item = currency, name = itemName(currency), money = currency == 'cash' },
        accounts  = nil,
        -- The header's talk capsule (html/js/shop-talk.js): whether it shows at all, and whose face the
        -- keeper's is (its model's picture; nil for a shop with an object or nobody behind the counter).
        talk      = Shops.talkEnabled(),
        keeper    = def.npcModel or nil,
    }

    if def.mode == 'stocked' and def.containerId then
        -- The shelf and its prices in memory before the screen is built from them.
        if not Containers.invCache[def.containerId] then
            Containers.loadInventory(def.containerId)
        end
        Shops.loadPrices(def.containerId)
    end

    -- The player's bank accounts for the payment dropdown: only ones they can pay from.
    if charId and currency == 'cash' then
        local accounts = Bank.GetCharacterAccounts(charId)
        if accounts then
            payload.accounts = {}
            for _, acct in ipairs(accounts) do
                if Bank.CanUse(charId, acct.accountId, 'withdraw') then
                    payload.accounts[#payload.accounts + 1] = {
                        accountId     = acct.accountId,
                        accountNumber = acct.accountNumber,
                        label         = acct.label,
                        type          = acct.type,
                        balance       = acct.balance,
                    }
                end
            end
        end
    end

    return payload
end

-- ============================================
-- Purchase Logic
-- ============================================

--- Buy everything in the player's basket: price what is held (the goods moved into the basket store
--- as they were picked), take the money once, and move it into their pockets.
---
--- Nothing comes from the client except the payment method, and the total the player was shown
--- (compared, never charged). Each line is priced here, from the shop's own record.
---@param source number
---@param paymentMethod string 'cash' = the shop's currency item | 'bank' = an account balance
---@param accountId number|nil
---@param expectedTotal number|nil  the total on the player's screen; -1 or nil when not given
---@return boolean success
---@return string|nil error
---@return table|nil receipt  the purchase, as whip_core:shop:purchased carries it
---@return string|nil kind  'carry' when it will not all fit (Shops.purchase's kind)
local function purchaseInner(source, paymentMethod, accountId, expectedTotal)
    local player = Players[source]
    if not player or not player.inventory then
        return false, 'Player not loaded'
    end

    local shopId = Shops._openShops[source]
    if not shopId then return false, 'Shop not open' end

    local def = Shops.getDef(shopId)
    if not def then return false, 'Shop not found' end

    local session = _basketSessions[source]
    if not session or next(session.items) == nil then
        return false, 'Empty basket'
    end

    if not Shops.inRange(source) then
        return false, 'Too far from shop'
    end

    -- ---- Price what is in the basket, at the shop's price NOW ----
    local lines, totalPrice = {}, 0
    for slot, entry in pairs(session.items) do
        local unit = Shops.itemPrice(def, entry.item)
        -- Taken off sale (or out of the catalog) while it sat in the basket. Refuse the whole
        -- purchase rather than guess a figure; the screen marks the line.
        if not unit then
            return false, ('%s is no longer for sale'):format(itemName(entry.item))
        end
        local amount = entry.amount or 1
        totalPrice = totalPrice + (unit * amount)
        lines[#lines + 1] = { slot = slot, item = entry.item, amount = amount, unit = unit }
    end

    if totalPrice < 0 then
        return false, 'Invalid total'
    end

    -- The total the player saw: an owner can change a price while it sits in a basket, and a change
    -- landing between the redraw and the click is refused rather than charged unseen.
    if expectedTotal and expectedTotal >= 0 and expectedTotal ~= totalPrice then
        return false, 'The prices changed. Check your basket and buy again.'
    end

    -- Deterministic order, so a partial failure is reproducible and the slot named in a warning
    -- is the slot that actually failed.
    table.sort(lines, function(a, b) return a.slot < b.slot end)

    -- Can they carry it? Asked BEFORE payment, so a full inventory costs nothing — and asked as the
    -- screen asks it (cannotCarry): room line by line, enough free slots for them all, and the weight.
    -- Of the SAME STORE delivery uses: the main pockets, never the accessory strip.
    local carryWhy = cannotCarry(source, session)
    -- 'carry': the screen's Buy turns amber, "You can't carry all of this!" (Shops.purchase's kind).
    if carryWhy then return false, carryWhy, nil, 'carry' end

    -- No stock check and no lock on the stock container: the goods were MOVED into this player's
    -- basket as they were picked, and `session.checkout` (set by Shops.purchase) freezes the basket.

    -- Where the takings go, asked BEFORE anyone is charged (see the revenue deposit below):
    --   * the account can take a deposit (a FROZEN one refuses);
    --   * the customer is not paying FROM that business's own accounts (the goods would be free).
    local paysBusiness = totalPrice > 0 and def.jobId and (def.mode == 'infinite' or def.mode == 'stocked')
        and (paymentMethod == 'bank' or ((def.settings and def.settings.currency) or 'cash') == 'cash')
    if paysBusiness then
        local jobAccounts = Bank.GetAccountsByJob(def.jobId)
        local revenue = jobAccounts and jobAccounts[1]
        if revenue and DbBool(revenue.frozen) then
            return false, 'This business cannot take payments right now'
        end
        if paymentMethod == 'bank' then
            for _, acc in ipairs(jobAccounts or {}) do
                if acc.accountId == accountId then
                    return false, 'You cannot pay a business from its own account'
                end
            end
        end
    end

    -- What this shop accepts, not what the framework calls money: per shop (a black market wants
    -- crypto, a chop shop gold). Absent means 'cash'.
    local currency = (def.settings and def.settings.currency) or 'cash'

    -- ---- Take the payment ----
    --
    -- Through Money, the charge-and-refund every payment in whip uses. A free basket still gets a
    -- receipt (of nothing), so the refunds below need no special case.
    if paymentMethod ~= 'cash' and paymentMethod ~= 'bank' then
        return false, 'Invalid payment method'
    end
    -- The bank pays in money: a shop that prices in an item takes only the item.
    if paymentMethod == 'bank' and currency ~= 'cash' then
        return false, ('This shop takes %s, not bank payments'):format(itemName(currency))
    end
    if paymentMethod == 'bank' and totalPrice > 0 and (not accountId or accountId == 0) then
        return false, 'No bank account selected'
    end
    -- HELD: taken now, written WITH the goods (the write below), not on its own before them (audit 20, SHOP-1).
    local receipt, payErr = Money.charge(source, totalPrice, {
        method    = paymentMethod,
        accountId = paymentMethod == 'bank' and accountId or nil,
        currency  = paymentMethod == 'cash' and currency or nil,
        reason    = 'Shop purchase: ' .. tostring(def.name),
    }, GetCurrentResourceName(), 'paid at ' .. tostring(def.name), 'held')
    if not receipt then
        if paymentMethod == 'bank' then return false, 'Bank payment failed: ' .. (payErr or 'Unknown') end
        return false, payErr or 'Payment failed'
    end

    -- ---- Move the goods into the buyer's pockets ----
    --
    -- One Stores.move per line, as every other drag in whip. Server-initiated, so the basket's
    -- beforeMove veto (a PLAYER dragging unpaid goods out) does not apply.
    local basket      = Stores.basket(source)
    local pocketStore = Stores.player(source, 'player')

    --- Give back `amount` of the payment — in the same item it was taken in (crypto for crypto,
    --- never banknotes for crypto), to the same account, dropped at their feet if their pockets
    --- are full. Money.refund's rules, and it says loudly when a refund cannot be delivered.
    local function refundMoney(amount)
        if amount <= 0 then return end
        local back, backErr = Money.refund(receipt, amount, GetCurrentResourceName())
        if not back then
            -- Said, and on their timeline (an item refund that did not arrive stays on the receipt,
            -- not passed on to the stock room below).
            print(('[whip_core:shops] CRITICAL: a refund of %d at "%s" for charId %s could not be delivered: %s')
                :format(amount, tostring(def.name), tostring(player.charId), tostring(backErr)))
            Log.write(player.charId, 'refund_failed', {
                itemKey = currency, amount = amount, detail = ('at %s · %s'):format(tostring(def.name), tostring(backErr)),
            })
        end
    end

    --- How a unit price reads in the activity log: '$5' for money, '5 Gold Bar' for anything else.
    local function priceText(unit)
        if paymentMethod == 'bank' or currency == 'cash' then return '$' .. tostring(unit) end
        local cdef = Config.Items[currency]
        return tostring(unit) .. ' ' .. ((cdef and cdef.name) or currency)
    end

    -- The same basket, or none of it: the payment above yields, and closing and reopening the shop
    -- meanwhile swaps in a NEW session. A basket that is not the one priced above is not delivered;
    -- the whole payment goes back.
    if _basketSessions[source] ~= session then
        refundMoney(totalPrice)
        return false, 'The shop closed while you were paying. You have been refunded.'
    end

    if not basket or not pocketStore then
        refundMoney(totalPrice)
        return false, 'Could not reach your inventory'
    end

    -- Refunded PER LINE: a line that cannot be delivered was not sold, and the rest need not fail.
    local refundDue = 0

    -- Exactly what was priced, refunded at what was charged: a line that no longer matches the
    -- figures captured at pricing is not delivered, and is refunded at its charged price.
    for _, line in ipairs(lines) do
        local entry = session.items[line.slot]

        -- (The session is asked again per line: nothing below yields today, but a swap part-way
        -- through delivery must refund the rest, not deliver it.)
        if _basketSessions[source] ~= session
            or not entry or entry.item ~= line.item or (entry.amount or 1) ~= line.amount then
            -- Gone or changed between pricing and delivery. Charged for, never handed over.
            refundDue = refundDue + (line.unit * line.amount)
        else
            -- Made for the buyer: off an infinite shelf an item was made for nobody (reason 'shelf');
            -- one whose generator asks for it (RegisterItemDefaultMeta ... { forBuyer = true }: a SIM
            -- with its buyer's number) is made again now. Stocked goods are real items and keep what
            -- they are.
            if def.mode ~= 'stocked' and Inventory.MetaForBuyer[entry.item] then
                local fresh = Inventory.runMetaGen(Inventory.MetaGenerators[entry.item], entry.item,
                    Inventory.metaContext(source, 'bought'))
                if fresh then entry.metadata = fresh end
            end
            local dest = slotAccepting(pocketStore, entry.item, line.amount, entry.metadata)
            local ok, err
            if dest then
                -- Stamped BEFORE the move so the uid travels with the goods into the pockets, and
                -- this purchase is the first row of that item's timeline (the log's uid is ignored
                -- when stacking, so this cannot stop a merge).
                Log.ensureUid(entry)
                ok, err = Stores.move(basket, line.slot, pocketStore, dest)
            else
                err = 'no room'
            end

            if ok then
                -- 'bought' is the Item Log's "came into the game" (Economy counts it): true of a catalog
                -- shop. A STOCKED shop's goods were already in the game, so they are 'received'.
                Log.item(player.charId, def.mode == 'stocked' and 'received' or 'bought', entry, {
                    amount = line.amount,
                    detail = ('at %s · %s each'):format(tostring(def.name), priceText(line.unit)),
                })
                line.delivered = true
            else
                refundDue = refundDue + (line.unit * line.amount)
                print(('[whip_core:shops] delivery failed for %s x%s at "%s": %s — refunded')
                    :format(tostring(entry.item), tostring(line.amount), tostring(def.name), tostring(err)))
            end
        end
    end

    refundMoney(refundDue)
    totalPrice = totalPrice - refundDue

    -- Paid in an item, into the stock room: only money reaches a business's account (see the revenue
    -- below), so an item payment goes into the shop's own container for its staff, before the save
    -- below so it lands with the sale. A shop with no container (infinite, NPC) spends it; a full
    -- stock room is said loudly. The buyer's own stacks (Money.handOn), metadata and all.
    if totalPrice > 0 and paymentMethod ~= 'bank' and currency ~= 'cash' and def.containerId then
        local stacks = Money.handOn(receipt, GetCurrentResourceName(), totalPrice)   -- what the delivered goods cost
        if not stacks then
            print(('[whip_core:shops] WARNING: the %d %s paid at "%s" could not be passed on to its stock room')
                :format(totalPrice, tostring(currency), tostring(def.name)))
        end
        for _, s in ipairs(stacks or {}) do
            local landed, landErr = Stores.giveAt({ kind = 'container', id = def.containerId }, currency, s.amount, s.metadata,
                { reason = 'paid at ' .. tostring(def.name) })
            if not landed then
                print(('[whip_core:shops] WARNING: %d %s paid at "%s" did not fit its stock room (container %s): %s')
                    :format(s.amount, tostring(currency), tostring(def.name), tostring(def.containerId), tostring(landErr)))
            end
        end
    end

    -- ONE WRITE: the payment (held on this action, above), the buyer's pockets, the shelf and the business's takings
    -- land together or not at all (audit 20, SHOP-1; Josh, 12 Oct: "the transaction itself is never lost"). The
    -- takings' deposit carries the rest (bank.lua bankWrite → Stores.commitWithAction); with no takings to pay in,
    -- saveAll does (a held payment rides any write of the units it pays for).
    local stockStore = def.mode == 'stocked' and def.containerId and Stores.container(def.containerId) or nil
    local together = { pocketStore, stockStore }

    -- Deposit revenue to business bank (modes infinite/stocked with jobId, skip if free), only when
    -- the customer paid in money (a bank account, or banknotes). An item is not converted into money.
    local paidIn = (paymentMethod == 'bank') and 'bank'
        or ((def.settings and def.settings.currency) or 'cash')
    local paidInMoney = paidIn == 'bank' or paidIn == 'cash'
    local written = false
    if totalPrice > 0 and paidInMoney and def.jobId and (def.mode == 'infinite' or def.mode == 'stocked') then
        local jobAccounts = Bank.GetAccountsByJob(def.jobId)
        if jobAccounts and #jobAccounts > 0 then
            local businessAccount = jobAccounts[1]
            local deposited, depositErr = Bank.SystemDeposit(businessAccount.accountId, totalPrice, 'Sale: ' .. def.name,
                player.charId, { with = together })
            written = deposited == true
            if not deposited then
                -- The customer has paid and has their goods (written just below, without it); this is the business
                -- losing the takings, which is exactly what must never be silent.
                print(('[whip_core:shops] CRITICAL: sale revenue of %d for "%s" could not be deposited to account %s: %s')
                    :format(totalPrice, tostring(def.name), tostring(businessAccount.accountId), tostring(depositErr)))
            end
        else
            print(('[whip_core:shops] WARNING: "%s" belongs to job %s, which has no bank account — %d in revenue went nowhere')
                :format(tostring(def.name), tostring(def.jobId), totalPrice))
        end
    end
    if not written then
        if stockStore or not (def.mode == 'stocked' and def.containerId) then
            pcall(Stores.saveAll, together)
        else
            pcall(Containers.saveInventory, def.containerId)
            pcall(Stores.saveAll, { pocketStore })
        end
    end
    Inventory.syncAndFlush(source, player)

    -- (The inventory was saved and synced above, before the revenue.)
    TriggerClientEvent('whip_core:client:updateCash', source, player:getCash())

    -- Fire event for external resources. `items` ({itemKey, amount, price}) is what was actually
    -- DELIVERED: a refunded line was not a sale.
    local sold = {}
    for _, line in ipairs(lines) do
        if line.delivered then
            sold[#sold + 1] = {
                itemKey = line.item,
                amount  = line.amount,
                price   = line.unit,
            }
        end
    end

    local purchase = {
        shopId        = shopId,
        charId        = player.charId,
        source        = source,
        items         = sold,
        total         = totalPrice,
        paymentMethod = paymentMethod,
        mode          = def.mode,
    }
    WhipEmit('whip_core:shop:purchased', purchase)

    -- The receipt rides back to Shops.purchase, for the shopper's "Paid $45 for x3 Water" (shop talk).
    return true, nil, purchase
end

--- Buy everything in the player's basket. See purchaseInner above for the transaction itself.
---
--- The basket is frozen for the whole checkout (the bank path yields): `session.checkout` is what
--- basketAction refuses on. Held in a wrapper so every way out of purchaseInner, a thrown error
--- included, lets go of it.
---@param source number
---@param paymentMethod string 'cash' = the shop's currency item | 'bank' = an account balance
---@param accountId number|nil
---@param expectedTotal number|nil  the total the player was shown (see purchaseInner)
---@return boolean success
---@return string|nil error
---@return string|nil kind  of a refusal, for the screen's Buy: 'money' (not enough of it), 'carry' (it
---                          will not all fit in their pockets), or nil (anything else)
function Shops.purchase(source, paymentMethod, accountId, expectedTotal)
    local session = _basketSessions[source]
    if session and session.checkout then
        return false, 'Already paying'
    end
    if session then session.checkout = true end

    local ok, success, err, receipt, kind = pcall(purchaseInner, source, paymentMethod, accountId, expectedTotal)

    if session then session.checkout = nil end

    -- The screen follows, whatever happened: Stores.move pushes nothing, and the page waits for a
    -- push rather than emptying the basket itself.
    Shops.pushScreen(source)

    if not ok then
        print(('[whip_core:shops] ERROR during purchase for src %s: %s'):format(tostring(source), tostring(success)))
        return false, 'Purchase failed'
    end
    -- Shop talk (server/shop_talk.lua): a sale is said as one ("Paid $45 for x3 Water"); a till that
    -- turned them down for want of money has the keeper make fun of them. Those are Money.charge's
    -- "Not enough <what> (have, need)" and the bank's "Insufficient funds" — and only those: a shop
    -- that cannot take payment, prices that changed, pockets that are full say nothing.
    if success then
        Shops.talkPaid(source, receipt)
    elseif type(err) == 'string' and (err:find('^Not enough ') or err:find('Insufficient funds', 1, true)) then
        kind = 'money'
        Shops.talkBroke(source)
    end
    return success, err, (not success) and kind or nil
end

-- ============================================
-- Shops — Server Exports
-- ============================================

--- One shop by its id. Found by anything else — its key, its stock container, its job — is GetShopBy,
--- the same pair vehicles have (GetVehicle / GetVehicleBy).
exports('GetShop', function(shopId) return Shops.getDef(tonumber(shopId)) end)
exports('GetAllShops', function() return Shops.getAll() end)

--- `(def)` or `(false, reason)`. Follows a changed declaration like EnsureZone; see Shops.ensureShop.
exports('EnsureShop', function(key, data)
    local caller = Registry.caller()   -- first, before anything can yield
    -- As every Ensure*: waits for whip_core's shops to load, or the key would read as new.
    if not WaitForCoreReady() then return false, NOT_READY end
    local def, err = Shops.ensureShop(key, data, caller)
    if not def then
        err = err or 'Could not create the shop'
        Registry.sayRefused(caller, ('EnsureShop("%s"): %s'):format(tostring(key), err))
        return false, err
    end
    return def
end)
exports('CreateShop', function(data)
    local caller = Registry.caller()   -- first, before anything can yield
    -- Who made it, so its blip shows only while that resource runs (Shops.ownerOf). On a copy: the
    -- caller's table is theirs.
    if type(data) == 'table' and caller ~= GetCurrentResourceName() then
        local copy = {}
        for k, v in pairs(data) do copy[k] = v end
        copy.settings = {}
        for k, v in pairs(type(data.settings) == 'table' and data.settings or {}) do copy.settings[k] = v end
        copy.settings.owner = caller
        data = copy
    end
    local def, err = Shops.create(data)
    if not def then return false, err or 'Could not create the shop' end
    return def
end)
-- A shop another running resource made (CreateShop) or declares (EnsureShop) is that resource's to change or
-- delete, as a zone is (DeleteZone). One made in /whip, or whose resource is not running, is open to any.
local function shopOfAnother(def, caller)
    local by = Shops.ownerOf(def)
    if by and by ~= caller and Registry.alive(by) then
        return ('shop "%s" belongs to %s: only it can change or delete it'):format(tostring(def.key or def.name), by)
    end
    return nil
end

exports('DeleteShop', function(shopId)
    local caller = Registry.caller()
    local def = Shops.getDef(tonumber(shopId))
    if not def then return false, 'Shop not found' end
    local theirs = shopOfAnother(def, caller)
    if theirs then return false, theirs end
    return Shops.delete(tonumber(shopId) --[[@as number]])
end)
exports('UpdateShop', function(shopId, data)
    local caller = Registry.caller()
    local def = Shops.getDef(tonumber(shopId))
    if not def then return false, 'Shop not found' end
    if type(data) ~= 'table' then return false, 'UpdateShop needs a data table' end
    local theirs = shopOfAnother(def, caller)
    if theirs then return false, theirs end
    return Shops.update(tonumber(shopId) --[[@as number]], data)
end)

--- A stocked shop's stock container, from either way an export names it: the containerId, or
--- `{ shopId = n }`, as every other shop export takes.
---@return number|false containerId
---@return string|nil err
local function stockTarget(target)
    if type(target) ~= 'table' then return target end
    local def = Shops.getDef(tonumber(target.shopId))
    if not def then return false, 'Shop not found' end
    if not def.containerId then return false, 'That shop has no stock container (not stocked mode)' end
    return def.containerId
end

--- The shop a stock container belongs to, or nil for a container that is no shop's.
local function shopOfContainer(containerId)
    containerId = tonumber(containerId)
    for _, def in pairs(Shops.cache) do
        if def.containerId == containerId then return def end
    end
    return nil
end

--- Price an item on a STOCKED shop's shelf, or take it off sale (forSale false keeps the price).
--- One price per item: every shelf slot holding it sells at it.
exports('SetShopItemPrice', function(target, itemKey, price, forSale)
    local caller = Registry.caller()
    local containerId, err = stockTarget(target)
    if not containerId then return false, err end
    local theirs = shopOfAnother(shopOfContainer(containerId), caller)
    if theirs then return false, theirs end
    return Shops.setItemPrice(containerId, itemKey, price, forSale)
end)

--- One shop, found by something other than its id — the GetVehicleBy shape:
---     GetShopBy('key', 'burgershot')   GetShopBy('containerId', 12)   GetShopBy('id', 4)
--- `'job'` answers with a LIST of that job's shops, since a job can own several.
---@param kind string  'id' | 'key' | 'containerId' | 'job'
---@param value any
---@return table|table[]|nil
exports('GetShopBy', function(kind, value)
    if kind == 'id' then return Shops.getDef(tonumber(value)) end
    if kind == 'key' then return Shops.getByKey(value) end
    if kind == 'containerId' then
        value = tonumber(value)
        for _, def in pairs(Shops.cache) do
            if def.containerId == value then return def end
        end
        return nil
    end
    if kind == 'job' then
        -- A job by jobId OR KEY, like every Jobs export.
        local job = Jobs.resolve(value)
        if not job then return {}, 'No such job' end
        local result = {}
        for _, def in pairs(Shops.cache) do
            if def.jobId == job.jobId then result[#result + 1] = def end
        end
        table.sort(result, function(a, b) return a.shopId < b.shopId end)
        return result
    end
    return nil
end)
exports('GetShopViewers', function(shopId)
    local viewers = {}
    for src, openId in pairs(Shops._openShops) do
        if openId == shopId then viewers[#viewers + 1] = src end
    end
    return viewers
end)
exports('GetShopCatalog', function(shopId) return Shops.getCatalog(shopId) end)
exports('AddCatalogItem', function(shopId, itemKey, price)
    local theirs = shopOfAnother(Shops.getDef(tonumber(shopId)), Registry.caller())
    if theirs then return false, theirs end
    return Shops.addCatalogItem(shopId, itemKey, price)
end)
exports('RemoveCatalogItem', function(shopId, itemKey)
    local theirs = shopOfAnother(Shops.getDef(tonumber(shopId)), Registry.caller())
    if theirs then return false, theirs end
    return Shops.removeCatalogItem(shopId, itemKey)
end)
-- `false` on refusal, not nil: an export's return list is cut at its first nil, which would drop
-- the reason.
exports('GetShopStock', function(shopId)
    local stock, err = Shops.getStock(shopId)
    if not stock then return false, err or 'No stock for that shop' end
    return stock
end)
--- A shop's tabs and where its goods sit (Shops.setLayout): `{ categories = { 'Food', 'Drinks' },
--- layout = { water = { category = 'Drinks', order = 1 } } }`. Either may be left out to keep the
--- shop's; an item the layout does not mention keeps its place.
exports('SetShopLayout', function(shopId, data)
    local def = Shops.getDef(tonumber(shopId))
    if not def then return false, 'Shop not found' end
    if type(data) ~= 'table' then return false, 'SetShopLayout needs { categories, layout }' end
    local theirs = shopOfAnother(def, Registry.caller())
    if theirs then return false, theirs end
    return Shops.setLayout(tonumber(shopId) --[[@as number]], data.categories, data.layout)
end)

--- `{ [itemKey] = { price, forSale } }`, per item.
exports('GetShopPrices', function(shopId)
    local prices, err = Shops.getPrices(shopId)
    if not prices then return false, err or 'No prices for that shop' end
    return prices
end)
