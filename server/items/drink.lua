-- ============================================
-- Item: drink (Water Bottle)
-- Consumable — restores thirst via Stats system
-- 100 = full, 0 = dehydrated. Drink adds toward 100.
-- ============================================

-- whip_core's functions, not its exports: see food.lua (and for why Stats.add's answer is returned).
local CORE = GetCurrentResourceName()

Inventory.registerUseHandler('drink', function(source)
    return Stats.add(source, 'thirst', 25, 'item:drink')
end, CORE)
