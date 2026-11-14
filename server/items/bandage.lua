-- ============================================
-- Item: bandage
-- Medical — heals 50 HP over 10 seconds via
-- the Stats effect system. Self-contained.
-- ============================================

-- whip_core's functions, not its exports: see food.lua. (A satellite: ApplyEffect / AddStat.)
local CORE = GetCurrentResourceName()

Inventory.registerUseHandler('bandage', function(source)
    -- Stats.applyEffect answers `true` or `false, reason`; a bandage that could not start healing is
    -- not used up.
    return Stats.applyEffect(source, 'healing', {
        duration  = 10,
        magnitude = 5,
        tickRate  = 1,
        onTick = function(src, _, effect)
            Stats.add(src, 'health', effect.magnitude, 'effect:healing')
        end,
    }, CORE)
end, CORE)
