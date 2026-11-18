-- ============================================
-- Item: wallet (Wallet)
-- 3 slots — accepts: cash, id_card, and any item registered with `wallet = true` (a bank card)
-- ============================================

-- Registered inline: the manifest loads this directory last. whip_core's function, not its export:
-- see food.lua.
Panels.registerItem('wallet', {
    slots        = 3,
    label        = 'Wallet',
    storageKey   = 'slots',
    -- The item keys it takes. (This said `cash = { maxPerSlot = 10000 }`, and nothing enforces a
    -- per-item cap — panels.lua says so — so it read as a limit that was not there.)
    allowedItems = { 'cash', 'id_card' },
    -- And any item whose definition says `wallet = true` (another resource's bank card, a licence):
    -- HasItem, GetItemCount and FindItem find those inside a wallet the player carries.
    allowedFlag  = 'wallet',
}, GetCurrentResourceName())
