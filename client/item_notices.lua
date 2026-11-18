-- ============================================
-- Item notices — client: the server's word that an item came or went, handed to the page
-- ============================================
--
-- server/item_notices.lua says what changed; html/js/item-notices.js draws the box. Where it sits is
-- Config.ItemNotices.position, read as each one arrives (so a change in /whip → Config shows on the next).

RegisterNetEvent('whip_core:client:itemNotice', function(n)
    if type(n) ~= 'table' then return end
    local cfg = Config.ItemNotices or {}
    n.action = 'itemNotice'
    n.position = cfg.position or 'right'
    SendNUIMessage(n)
end)
