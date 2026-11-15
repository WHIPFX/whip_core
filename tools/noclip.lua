-- ============================================
-- Dev Tools — Noclip
-- ============================================
--
-- The camera is client/freecam.lua's (shared with the furnisher); every number that affects how it
-- handles lives there. Noclip is a free camera you toggle that drops you wherever you flew to, and the car
-- you sit in with you, still in your seat.

ToolHandlers['Noclip'] = {
    enter = function()
        -- Defaults throughout: the ped hides, plain scroll zooms and Shift+scroll changes fly
        -- speed. That IS noclip, so none of it is stated — but for the controller: it follows the device
        -- in hand, so a pad flies it as the furnisher does — the left stick flies, the right looks, RT
        -- and LT go up and down, L3 held is fast. And the car: `vehicle` brings it along (not one
        -- another player drives).
        FreeCam.start({ pad = 'auto', vehicle = true })
    end,
    exit = function()
        -- movePed defaults to true, and it is named anyway. Going where you flew is the entire
        -- point of noclip rather than an incidental default, and the furnisher passing false is
        -- what makes that worth saying out loud in both places.
        FreeCam.stop({ movePed = true })
    end,
}
