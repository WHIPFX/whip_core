-- ============================================
-- SHOPS — Client Module
-- Prop streaming, blips, sync events, NUI callbacks
-- ============================================
--
-- A shop's keeper and its prompt are the server's (server/shop_counters.lua): the keeper is one of
-- whip's NPCs, and Browse / Manage Stock are a prompt riding it. What is here: a shop with a PROP
-- instead of a keeper has it made in each game (the prompt over it is the server's too), the blips,
-- and the shop screen.

local shopDefs      = {}   -- [shopId] = shop definition data
local propShops     = {}   -- [shopId] = the definition, for a shop with a prop and no keeper
local shopEntities  = {}   -- [shopId] = prop entity handle
local shopBlips     = {}   -- [shopId] = blip handle

ActiveShopId   = nil  -- Global — shared with inventory.lua

-- ============================================
-- Prop Spawning / Despawning
-- ============================================

local shopSpawning = {}  -- [shopId] = true while spawn thread is running

--- The shops whose prop this game makes: a prop, and no keeper (a keeper is the server's NPC).
local function refreshPropShops()
    propShops = {}
    for shopId, data in pairs(shopDefs) do
        if data.prop and not data.npcModel then propShops[shopId] = data end
    end
end

local function SpawnShopEntity(data)
    if shopEntities[data.shopId] then return end
    if shopSpawning[data.shopId] then return end
    shopSpawning[data.shopId] = true

    -- Spawn in own thread so we don't block the streaming loop
    CreateThread(function()
        local entity
        local shopId = data.shopId

        if data.prop and not data.npcModel then
            local model = GetHashKey(data.prop)

            if not IsModelInCdimage(model) then
                print(('[whip_core:shop] WARNING: Prop model "%s" does not exist (shop #%d)'):format(data.prop, shopId))
                shopSpawning[shopId] = nil
                return
            end

            if not LoadModel(model, 10000) then
                print(('[whip_core:shop] WARNING: Failed to load prop "%s" for shop #%d (timeout)'):format(data.prop, shopId))
                shopSpawning[shopId] = nil
                return
            end
            -- Deleted or changed while it loaded (up to 10 s on a cold cache): not made. The old prop, made anyway, was
            -- never streamed out again (audit 20, SHOP-2); the stream makes the new one.
            if propShops[shopId] ~= data then
                SetModelAsNoLongerNeeded(model)
                shopSpawning[shopId] = nil
                return
            end

            entity = CreateObject(model, data.x, data.y, data.z, false, false, false)
            if not entity or entity == 0 then
                SetModelAsNoLongerNeeded(model)
                shopSpawning[shopId] = nil
                return
            end

            SetEntityHeading(entity, data.heading or 0.0)
            FreezeEntityPosition(entity, true)
            PlaceObjectOnGroundProperly(entity)
            SetEntityAsMissionEntity(entity, true, true)
            SetModelAsNoLongerNeeded(model)
        else
            shopSpawning[shopId] = nil
            return
        end

        shopEntities[shopId] = entity
        shopSpawning[shopId] = nil
    end)
end

local function DespawnShopEntity(shopId)
    local entity = shopEntities[shopId]
    if entity then
        if DoesEntityExist(entity) then
            DeleteEntity(entity)
        end
        shopEntities[shopId] = nil
    end
end

-- ============================================
-- Blip Management
-- ============================================

local function CreateShopBlip(data)
    if shopBlips[data.shopId] then return end
    -- No icon asked for: none, including 0, which GTA would draw as its "higher" arrow. And none
    -- while the resource that made the shop is not running (Shops.wireOne's ownerAway).
    if not data.blipSprite or data.blipSprite == 0 or data.ownerAway then return end

    local blip = AddBlipForCoord(data.x, data.y, data.z)
    SetBlipSprite(blip, data.blipSprite)
    SetBlipColour(blip, data.blipColor or 2)
    SetBlipScale(blip, 0.8)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(data.name or 'Shop')
    EndTextCommandSetBlipName(blip)

    shopBlips[data.shopId] = blip
end

local function RemoveShopBlip(shopId)
    local blip = shopBlips[shopId]
    if blip then
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
        shopBlips[shopId] = nil
    end
end

-- ============================================
-- Server → Client: Sync Events
-- ============================================

--- Full sync (on connect/load)
RegisterNetEvent('whip_core:client:shopsSync', function(shops)
    shopDefs = {}
    if shops then
        if type(shops) == 'table' then
            for _, data in ipairs(shops) do
                if data and data.shopId then
                    shopDefs[data.shopId] = data
                end
            end
            -- Also handle key-value format
            for _, data in pairs(shops) do
                if data and data.shopId and not shopDefs[data.shopId] then
                    shopDefs[data.shopId] = data
                end
            end
        end
    end

    -- Create blips
    for _, blip in pairs(shopBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    shopBlips = {}
    for _, data in pairs(shopDefs) do
        CreateShopBlip(data)
    end
    refreshPropShops()
    -- A prop of a shop this list no longer has goes: the stream only walks the shops there are
    for shopId in pairs(shopEntities) do
        if not propShops[shopId] then DespawnShopEntity(shopId) end
    end
end)

--- Single shop created
RegisterNetEvent('whip_core:client:shopCreated', function(data)
    if not data or not data.shopId then return end
    shopDefs[data.shopId] = data
    CreateShopBlip(data)
    refreshPropShops()
end)

--- Single shop updated
RegisterNetEvent('whip_core:client:shopUpdated', function(data)
    if not data or not data.shopId then return end
    DespawnShopEntity(data.shopId)
    RemoveShopBlip(data.shopId)
    shopDefs[data.shopId] = data
    CreateShopBlip(data)
    refreshPropShops()
end)

--- Single shop deleted
RegisterNetEvent('whip_core:client:shopDeleted', function(shopId)
    if not shopId then return end
    DespawnShopEntity(shopId)
    RemoveShopBlip(shopId)
    shopDefs[shopId] = nil
    refreshPropShops()
end)

-- ============================================
-- Streaming — spawn/despawn handled by the shared StreamProps thread
-- (client/streamprops.lua; containers.lua registers the same way)
-- ============================================

StreamProps.addStream({
    name      = 'shops',
    -- Getter, not the table: the shop events above rebuild it wholesale. Only the prop shops: a
    -- keeper is the server's NPC.
    defs      = function() return propShops end,
    range     = function() return Config.ShopStreamRange or 100.0 end,
    isSpawned = function(id) return shopEntities[id] ~= nil end,
    spawn     = SpawnShopEntity,
    despawn   = DespawnShopEntity,
})

-- ============================================
-- Shop Open / Close
-- ============================================

RegisterNetEvent('whip_core:client:openShop', function(payload)
    if not payload then
        ActiveShopId = nil
        return
    end
    -- Declined open still owes a release: the server has set Shops._openShops[source], and
    -- a stocked shop has also taken its stock container's lock.
    if not OpenInventoryUI('openInventoryWithShop', payload, { shopId = payload.shopId }) then
        TriggerServerEvent('whip_core:server:closeShop')
    end
end)

RegisterNetEvent('whip_core:client:shopClosed', function()
    if not ActiveShopId then return end
    ActiveShopId = nil
    -- Full cleanup (mirrors CloseInventory)
    CloseInventory()
end)

RegisterNetEvent('whip_core:client:shopPurchaseResult', function(result)
    SendNUIMessage({
        action = 'shopPurchaseResult',
        data = result,
    })
end)

--- A line of this visit's shop talk, for the shop screen's header (server/shop_talk.lua,
--- html/js/shop-talk.js): who = 'me' | 'keeper'. The page ignores it when no shop is open.
RegisterNetEvent('whip_core:client:shopTalk', function(who, text, kind)
    if (who ~= 'me' and who ~= 'keeper') or type(text) ~= 'string' or text == '' then return end
    -- kind: 'sale' (a purchase went through) or 'refused' (not enough money), which the page colours.
    if kind ~= 'sale' and kind ~= 'refused' then kind = nil end
    SendNUIMessage({ action = 'shopTalk', who = who, text = text, kind = kind })
end)

--- The shelf and the basket, after anything moved on either side of the screen.
---
--- Both grids are server state, so this is the only thing that draws them.
RegisterNetEvent('whip_core:client:shopScreenUpdate', function(state)
    SendNUIMessage({
        action = 'shopScreenUpdate',
        data = state,
    })
end)

-- ============================================
-- Stock Management (employee view)
-- Routes through the existing container open flow.
-- Server sends whip_core:client:openContainer directly,
-- so containers.lua handles the UI (single handler).
-- Opened from the shop's prompt (Manage Stock), whose
-- press the server checks; a second press while the
-- stock is open finds the prompts closed by the screen.
-- ============================================

-- ============================================
-- NUI Callbacks
-- ============================================

-- (Closing goes through CloseInventory in inventory.lua.)

--- The basket is a server-side store, priced by the server. Sent: how the player would like to pay,
--- and the total on their screen, which the till compares with its own (a difference is refused).
RegisterNUICallback('shopPurchase', function(data, cb)
    if not ActiveShopId then
        cb('error')
        return
    end
    TriggerServerEvent('whip_core:server:shopPurchase',
        data.paymentMethod or 'cash',
        data.accountId or 0,
        tonumber(data.expectedTotal) or -1
    )
    cb('ok')
end)

--- An item off the shelf into the basket: a tile's click, the pad's A, or "Add several". By item,
--- never by shelf slot; the server finds it on the shelf and pushes back the screen.
RegisterNUICallback('basketAdd', function(data, cb)
    if not ActiveShopId then
        cb('error')
        return
    end
    TriggerServerEvent('whip_core:server:basketAdd', data.item or '', data.amount or 1)
    cb('ok')
end)

--- Edit Shelf's Save: the shop's tabs and where its goods sit. The server checks the player may
--- arrange this shop (its managers, whip's admins) and redraws every customer there.
RegisterNUICallback('shopSetLayout', function(data, cb)
    if not ActiveShopId then
        cb('error')
        return
    end
    -- layoutRev: the shelf's revision the draft was made from; -1 when the page did not say
    TriggerServerEvent('whip_core:server:shopSetLayout', data.categories or {}, data.layout or {},
        math.tointeger(tonumber(data.layoutRev)) or -1)
    cb('ok')
end)

--- A basket line's minus / plus / remove, and its "Set Quantity". The server does the arithmetic
--- through the store movers and pushes back the screen — the NUI never guesses at stock.
RegisterNUICallback('basketSetQuantity', function(data, cb)
    if not ActiveShopId then
        cb('error')
        return
    end
    TriggerServerEvent('whip_core:server:basketSetQuantity',
        data.slot or 0,
        data.quantity or 0
    )
    cb('ok')
end)

--- How many of an item the basket should hold, all its lines together: the plus and minus,
--- a typed number, a held button. Answered when the server has done it, so the page can send the next
--- total the player asked for (html/js/shops.js): { ok, total } or { ok = false }.
RegisterNUICallback('basketSetItem', function(data, cb)
    if not ActiveShopId or type(data) ~= 'table' then
        cb({ ok = false })
        return
    end
    local from = type(data.from) == 'table' and data.from or {}
    local res, why = Callback('whip_core:basketSetItem', tostring(data.item or ''),
        math.tointeger(tonumber(data.quantity)) or 0, from)
    -- A refusal's reason goes on: the page sends again after a 'Rate limited', and only then.
    cb(type(res) == 'table' and res or { ok = false, why = type(why) == 'string' and why or nil })
end)

RegisterNUICallback('shopSetPrice', function(data, cb)
    -- keepPrice: Mark For Sale changes only the for-sale, at the item's price as the server has it
    -- item: what was on the slot when pressed; the server refuses if the slot holds something else now
    TriggerServerEvent('whip_core:server:shopSetPrice',
        data.shopId or 0,
        data.slot or 0,
        data.price or 0,
        data.forSale and true or false,
        data.keepPrice == true,
        data.keepSale == true,
        type(data.item) == 'string' and data.item or ''
    )
    cb('ok')
end)

RegisterNUICallback('shopPriceInput', function(data, cb)
    cb('ok')

    local shopId = data.shopId
    local slotNum = data.slot
    local itemKey = type(data.item) == 'string' and data.item or ''   -- what the menu was opened on

    -- UI.Input closes the inventory itself before it opens.
    Citizen.CreateThread(function()
        local result = UI.Input('Set Item Price', {
            { label = 'Price ($)', type = 'number', placeholder = 'Enter price...', default = data.currentPrice or 0, min = 0, max = 999999 },
        })

        if result then
            -- result[1]: the dialog answers with a list (ui.js).
            local rawVal = result[1]
            local newPrice = math.max(0, math.floor(tonumber(rawVal) or 0))

            -- keepSale: the price changes, its for-sale stays as the server has it. itemKey: the
            -- dialog waited on the player, and the slot may hold something else by now.
            TriggerServerEvent('whip_core:server:shopSetPrice',
                shopId,
                slotNum,
                newPrice,
                false,
                false,
                true,
                itemKey
            )
        end

        -- Re-open stock management (server sends openContainer back)
        Wait(200)
        TriggerServerEvent('whip_core:server:openShopStock', shopId)
    end)
end)

-- ============================================
-- Cleanup
-- ============================================

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    for id in pairs(shopEntities) do
        DespawnShopEntity(id)
    end
    for _, blip in pairs(shopBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
end)

-- ============================================
-- Client Exports
-- ============================================

exports('IsShopOpen', function() return ActiveShopId ~= nil end)
exports('GetActiveShopId', function() return ActiveShopId end)
