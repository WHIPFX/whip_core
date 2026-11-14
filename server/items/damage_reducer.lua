-- ============================================
-- Item: damage_reducer
-- Consumable — take 5% of incoming weapon damage for 20s
-- ============================================

-- whip_core's functions, not its exports: see food.lua. (A satellite: ApplyEffect / NotifyPlayer.)
local CORE = GetCurrentResourceName()

Inventory.registerUseHandler('damage_reducer', function(source)
    -- Its answer is the handler's: a reducer that could not be applied is not used up.
    return Stats.applyEffect(source, 'damage_reduction', {
        duration       = 20,
        -- A MULTIPLIER, not an amount removed. Incoming damage is multiplied by this, so 0.05
        -- means the player takes a twentieth of what hit them. Different effects' modifiers
        -- multiply together (Stats.getDamageModifier), but a SECOND use of this item does not
        -- stack with the first: effects are keyed by name, so it replaces it and restarts the 20s.
        damageModifier = 0.05,
        onApply = function(src)
            NotifyPlayer(src, '95% damage reduction for 20 seconds', 'success')
        end,
        onRemove = function(src)
            NotifyPlayer(src, 'Damage reduction wore off', 'warning')
        end,
    }, CORE)
end, CORE)
