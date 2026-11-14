-- ============================================
-- Item: food (Burger)
-- Consumable — restores hunger via Stats system
-- 100 = full, 0 = starving. Food adds toward 100.
-- ============================================
--
-- whip_core's own items call whip_core's functions: an export called from inside whip_core is a full
-- round trip on a fresh coroutine that no player action owns, so the hunger change would be written
-- apart from the burger it ate. Called directly, they land together.
--
-- The same item in a satellite uses the exports, inside `Whip.register(function() ... end)` (include
-- '@whip_core/lib/satellite.lua' in the fxmanifest), as whip_drunk_example does:
--
--     exports.whip_core:RegisterUseHandler('food', function(source)
--         return exports.whip_core:AddStat(source, 'hunger', 25, 'item:food')
--     end)
--
-- Returning true consumes one of the item; returning false leaves the stack alone. Stats.add answers
-- `true` or `false, reason` — returned as it is, so a bite that did nothing (the stat refused) does
-- not eat the burger.

local CORE = GetCurrentResourceName()

Inventory.registerUseHandler('food', function(source)
    return Stats.add(source, 'hunger', 25, 'item:food')
end, CORE)
