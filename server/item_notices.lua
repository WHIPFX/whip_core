-- ============================================
-- Item notices — the box at the side of the screen when a player gets or loses an item
-- ============================================
--
-- From whip_core:item:added / :removed (Inventory.announceChanges), so every way an item reaches the pockets
-- shows it: an admin's give, a shop, a job, a satellite's AddItem, a pick up, another player's hand. A move
-- between the player's own slots changes no count and shows nothing. Config.ItemNotices turns it on and off,
-- and says whether losses show too (read here at the moment of use: /whip → Config changes it live).

local function itemNotice(e, added)
    local cfg = Config.ItemNotices
    if type(cfg) ~= 'table' or cfg.enabled == false then return end
    if not added and cfg.removed == false then return end
    if type(e) ~= 'table' or not e.source or not e.item then return end
    local def = Config.Items[e.item]
    TriggerClientEvent('whip_core:client:itemNotice', e.source, {
        item   = e.item,
        name   = def and def.name or e.item,
        img    = def and Inventory.resolveItemImage(e.item, def) or nil,
        amount = tonumber(e.amount) or 1,
        count  = tonumber(e.count) or 0,
        added  = added,
    })
end

AddEventHandler('whip_core:item:added',   function(e) itemNotice(e, true) end)
AddEventHandler('whip_core:item:removed', function(e) itemNotice(e, false) end)
