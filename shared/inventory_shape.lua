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
