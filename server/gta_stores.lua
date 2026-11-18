-- ============================================
-- GTA STORES — server/gta_stores.lua: the game's own 24/7s and LTDs, as whip shops
-- ============================================
--
-- Opened by Config.GtaStores (config.lua; on for a server WHIP's txAdmin recipe sets up). Each is made once, under
-- its key, when no shop has it (Shops.seedFromConfig), and is then a shop like any other: moved, priced and
-- stocked in /whip > Economy > Shops.
--
-- WHERE THE KEEPER STANDS, worked out from the game's own map: each store's interior as GTA places it (a v_shop_247
-- or a v_gasstation, its position and rotation in the map files) and that interior's first till (prop_till_01, from
-- its own entity list), half a metre behind it, facing the customers. The same spot in every copy of the room.

GtaStores = {
    { key = 'gta_store_strawberry', name = '24/7 Supermarket', pos = vector4(24.47, -1346.62, 29.50, 270.00) },   -- Innocence Blvd, Strawberry
    { key = 'gta_store_vinewood', name = '24/7 Supermarket', pos = vector4(372.73, 327.09, 103.57, 255.86) },   -- Clinton Ave, Vinewood
    { key = 'gta_store_tataviam', name = '24/7 Supermarket', pos = vector4(2556.52, 380.85, 108.62, 357.73) },   -- Palomino Fwy, Tataviam
    { key = 'gta_store_banham', name = '24/7 Supermarket', pos = vector4(-3039.62, 584.32, 7.91, 17.82) },   -- Great Ocean Hwy, Banham Canyon
    { key = 'gta_store_chumash', name = '24/7 Supermarket', pos = vector4(-3242.96, 1000.04, 12.83, 355.06) },   -- Barbareno Rd, Chumash
    { key = 'gta_store_harmony', name = '24/7 Supermarket', pos = vector4(549.16, 2670.66, 42.16, 97.45) },   -- Route 68, Harmony
    { key = 'gta_store_senora', name = '24/7 Supermarket', pos = vector4(2677.44, 3279.74, 55.24, 330.93) },   -- Senora Fwy, Grand Senora Desert
    { key = 'gta_store_sandy', name = '24/7 Supermarket', pos = vector4(1959.74, 3740.61, 32.34, 300.02) },   -- Alhambra Dr, Sandy Shores
    { key = 'gta_store_paleto', name = '24/7 Supermarket', pos = vector4(1728.16, 6415.84, 35.04, 243.65) },   -- Great Ocean Hwy, Paleto Bay
    { key = 'gta_store_davis', name = 'LTD Gasoline', pos = vector4(-46.92, -1758.09, 29.42, 50.01) },   -- Grove St, Davis
    { key = 'gta_store_littleseoul', name = 'LTD Gasoline', pos = vector4(-706.15, -913.83, 19.22, 90.00) },   -- Palomino Ave, Little Seoul
    { key = 'gta_store_richman', name = 'LTD Gasoline', pos = vector4(-1820.03, 794.02, 138.24, 132.45) },   -- Banham Canyon Dr, Richman Glen
    { key = 'gta_store_mirrorpark', name = 'LTD Gasoline', pos = vector4(1164.71, -322.95, 69.21, 99.98) },   -- Mirror Park Blvd, Mirror Park
    { key = 'gta_store_grapeseed', name = 'LTD Gasoline', pos = vector4(1697.91, 4923.05, 42.06, 325.03) },   -- Grapeseed Main St, Grapeseed
}
