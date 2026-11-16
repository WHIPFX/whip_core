-- Default public garages included in the unofficial JBC Core bundle.
local function public(key, name, marker, bay)
    return { key = key, name = name, marker = marker, bay = bay }
end
local defaults = {
        public('legion_square', 'Public Garage', vector3(819.95, -821.92, 26.18), vector4(822.0, -818.0, 26.18, 123.63)),
        public('whip_motelgarage', 'Motel Parking', vector3(274.29, -334.15, 44.92), vector4(265.96, -332.3, 44.51, 250.68)),
        public('whip_casinogarage', 'Casino Parking', vector3(883.96, -4.71, 78.76), vector4(895.39, -4.75, 78.35, 146.85)),
        public('whip_sapcounsel', 'San Andreas Parking', vector3(-330.01, -780.33, 33.96), vector4(-341.57, -767.45, 33.56, 92.61)),
        public('whip_spanishave', 'Spanish Avenue Parking', vector3(-1160.86, -741.41, 19.63), vector4(-1145.2, -745.42, 19.26, 108.22)),
        public('whip_caears24', 'Caesars 24 Parking North', vector3(69.84, 12.6, 68.96), vector4(60.8, 17.54, 68.82, 339.7)),
        public('whip_caears242', 'Caesars 24 Parking West', vector3(-453.7, -786.78, 30.56), vector4(-472.39, -787.71, 30.14, 180.52)),
        public('whip_lagunapi', 'Laguna Parking', vector3(364.37, 297.83, 103.49), vector4(375.09, 294.66, 102.86, 164.04)),
        public('whip_airportp', 'LSIA Parking', vector3(-773.12, -2033.04, 8.88), vector4(-779.77, -2040.18, 8.47, 315.34)),
        public('whip_beachp', 'Vespucci Beach Parking', vector3(-1185.32, -1500.64, 4.38), vector4(-1188.14, -1487.95, 3.97, 124.06)),
        public('whip_themotorhotel', 'Motor Hotel Parking', vector3(1137.77, 2663.54, 37.9), vector4(1127.7, 2647.84, 37.58, 1.41)),
        public('whip_liqourparking', 'Route 68 Liquor Parking', vector3(883.99, 3649.67, 32.87), vector4(898.38, 3649.41, 32.36, 90.75)),
        public('whip_shoreparking', 'Sandy Shores Parking', vector3(1737.03, 3718.88, 34.05), vector4(1725.4, 3716.78, 34.15, 20.54)),
        public('whip_haanparking', 'Paleto Bay Parking', vector3(76.88, 6397.3, 31.23), vector4(62.15, 6403.41, 30.81, 211.38)),
        public('whip_pillboxgarage', 'Pillbox Parking', vector3(213.2, -796.05, 30.86), vector4(222.02, -804.19, 30.26, 248.19)),
        public('whip_grapeseedgarage', 'Grapeseed Parking', vector3(2552.68, 4671.8, 33.95), vector4(2550.17, 4681.96, 33.81, 17.05)),
}

-- Default public bays are provisioned once per boot, before players can use them.
local function nearestExisting(seed)
    for _, position in ipairs({ seed.marker, seed.bay }) do
        if Garages.nearest(position.x, position.y, position.z, 25.0) then return true end
        for _, garage in pairs(Garages.getAll()) do
            if Garages.isPrivate(garage.key) and #(vector3(position.x, position.y, position.z) - vector3(garage.x, garage.y, garage.z)) <= 8.0 then
                return true
            end
        end
    end
    return false
end

local function reconcile(seed)
    local key, point = seed.key, seed.bay
    local garage = Garages.get(key)
    if not garage then
        if nearestExisting(seed) then return true end
        local m = seed.marker
        local created, why = Garages.create({
            key = key, name = seed.name,
            x = m.x, y = m.y, z = m.z, heading = point.w,
            spawnX = point.x, spawnY = point.y, spawnZ = point.z, spawnHeading = point.w,
            blipSprite = 357, blipColor = 3,
        }, GetCurrentResourceName())
        if not created then return false, why end
        garage = Garages.get(key)
    end
    if Garages.isPrivate(key) then return true end
    local stockLegion = key == 'legion_square' and not garage.resource
        and #(vector3(garage.x, garage.y, garage.z) - seed.marker) <= 1.0
    if garage.resource ~= 'whip_garages' and garage.resource ~= GetCurrentResourceName() and not stockLegion then
        return true
    end
    if garage.resource == 'whip_garages' then
        local owner = GetCurrentResourceName()
        MySQL.update.await('UPDATE `garages` SET `resource` = ? WHERE `key` = ? AND `resource` = ?', { owner, key, 'whip_garages' })
        garage.resource = owner
    end

    local bays, retained, bestScore = {}, nil, math.huge
    for _, bay in ipairs(GarageSpots.all()) do
        if bay.garageKey == key then
            bays[#bays + 1] = bay
            local score = (bay.x - point.x)^2 + (bay.y - point.y)^2 + (bay.z - point.z)^2
            if score < bestScore or (score == bestScore and retained and bay.spotId < retained.spotId) then
                retained, bestScore = bay, score
            end
        end
    end
    if not retained then
        return GarageSpots.create(key, point.x, point.y, point.z, point.w)
    end
    -- Keep the native bay ID. Correct managed sites back to the configured defaults.
    local headingDelta = math.abs(((retained.heading - point.w + 180.0) % 360.0) - 180.0)
    if bestScore > 0.0025 or headingDelta > 0.1 then
        local moved, why = GarageSpots.update(retained.spotId, point.x, point.y, point.z, point.w)
        if not moved then return false, why end
    end
    for _, bay in ipairs(bays) do
        if bay.spotId ~= retained.spotId then
            local removed, why = GarageSpots.delete(bay.spotId)
            if not removed then return false, why end
        end
    end
    return true
end

function JbcGarageSetup()
    for _, seed in ipairs(defaults) do
        local ran, ok, why = pcall(reconcile, seed)
        if not ran or not ok then
            print(('[whip_core:garage] Could not set up %s: %s'):format(seed.key, tostring(ran and why or ok)))
        end
    end
end
