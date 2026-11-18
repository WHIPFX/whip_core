-- ============================================
-- The containers every character has (both sides)
-- ============================================
--
-- A character's own containers: their inventory ('player') and the accessory strip ('accessory'), in the order the
-- inventory screen draws them.
--
-- Not a setting: the database stores only these two (inventory.lua's ENUM) and the screen draws only them. There is
-- no "backpack" container: bags are ordinary items (duffle_bag).
--
-- With Config.AccessoryStrip = false it is the inventory alone. Every path that takes a container checks this list,
-- so the strip is closed everywhere at once; its contents move into the inventory at login (Inventory.load).
--
-- After shared/settings.lua: AccessoryStrip as saved in /whip → Settings, not only as config.lua says.

PlayerContainers = Config.AccessoryStrip == false and { 'player' } or { 'player', 'accessory' }

-- The accessory strip's slots: what each one is called and what it takes.
--
-- Registerable, like stats. These five seed the registry (server/inventory.lua); a resource can add or replace a
-- slot at runtime with exports.whip_core:RegisterAccessorySlot{ slot = 4, accepts = 'badge', label = 'Badge' } and
-- the strip changes on every client with no NUI edit. `accepts` is an item, or a list of items; `keys = true` takes
-- any ignition key as well (RegisterIgnitionKey); with neither the slot takes anything. `icon` names one of the
-- NUI's built-in placeholder icons ('accessory', 'plus', 'phone', 'vehicle_key', 'cash'), and a registration may
-- instead carry `iconSvg` with its own inline SVG. With neither, the slot shows what it does: the icon for what it
-- accepts, or that item's own picture greyed, and a slot that takes anything the pouch ('accessory'). The rule is
-- enforced on the server (the player store kind's allowsAt and beforeMove); the NUI's copy only makes refusals
-- instant.
--
-- whip's own five: slot 1 is the Phone slot, which takes anything until whip_phone runs and keeps it to phones (it
-- looks for a phone there first, then everywhere); slot 2 is Money (cash or a wallet); slots 3 to 5 are Keys. A car key in a strip slot
-- goes into the ignition by itself when its holder takes the driver's seat, and back when they leave it
-- (server/events_vehicles.lua), so the three Key slots hold up to three cars' keys. The strip can never be set
-- smaller than the highest slot here (/whip → Settings, Accessory Inventory Size).
AccessoryStripSlots = {
    { slot = 1, label = 'Phone', icon = 'phone' },
    { slot = 2, label = 'Money', accepts = { 'cash', 'wallet' }, icon = 'cash' },
    { slot = 3, label = 'Key', keys = true, icon = 'vehicle_key' },
    { slot = 4, label = 'Key', keys = true, icon = 'vehicle_key' },
    { slot = 5, label = 'Key', keys = true, icon = 'vehicle_key' },
}

-- ============================================
-- Items that stay the player's inside another (both sides)
-- ============================================
--
-- A panel item may name an item field as its allowedFlag (the wallet's 'wallet', server/panels.lua). An item whose
-- definition sets that field to true (a bank card's `wallet = true`) is still on the player while it is inside one:
-- every count and take of what a player carries looks in those holders too, after the pockets. HasItem,
-- GetItemCount, RemoveItem, FindItem, FindAllItems, the `item` requirement of prompts, points and doors, and the
-- item events all agree. Only such items: cash in a wallet is put away (the money system pays from the pockets),
-- and a bag's contents stay the bag's.
--
-- The rule is the server's panel registrations. Each side passes `holdOf(holderItem)`, the holder's slot array as
-- { storageKey, slots } or nil, and `counts(holderItem, item)`: the server from Panels.itemConfigs and the item
-- definitions, a game from the definitions the server sends it (`holds`, `insideOf`: Inventory.getItemDefs).

--- Each stack of `item` (every counted one, when nil) inside a holder in `cache`, a character's containers: pockets
--- in order, then the holder's slot, then the place inside it, as fn(container, slot, place, data, inner, key); fn
--- answering true stops the walk. `key` is the place as the holder's array keys it (JSON may have made it text).
---@param cache table|nil
---@param item string|nil
---@param holdOf fun(holderItem: string): table|nil
---@param counts fun(holderItem: string, item: string): boolean
---@param fn fun(container: string, slot: number, place: number, data: table, inner: table, key: any): boolean|nil
function EachCarriedInside(cache, item, holdOf, counts, fn)
    if type(cache) ~= 'table' then return end
    for _, container in ipairs(PlayerContainers) do
        local slots = cache[container]
        if type(slots) == 'table' then
            for slot = 1, (Config.ContainerSlots[container] or 0) do
                local holder = slots[slot] or slots[tostring(slot)]
                local hold = type(holder) == 'table' and holder.item and holdOf(holder.item)
                local inner = hold and type(holder.metadata) == 'table' and holder.metadata[hold.storageKey or 'slots']
                if type(inner) == 'table' then
                    for place = 1, (hold.slots or 3) do
                        local key = inner[place] ~= nil and place or tostring(place)
                        local data = inner[key]
                        if type(data) == 'table' and data.item and (item == nil or data.item == item)
                            and counts(holder.item, data.item) and fn(container, slot, place, data, inner, key) then
                            return
                        end
                    end
                end
            end
        end
    end
end
