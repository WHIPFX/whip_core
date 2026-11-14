-- ============================================
-- VEHICLE CATALOG — server/vehicle_catalog.lua
-- ============================================
--
-- Every vehicle whip knows by name: its display name, its class, and whether it has a picture. The dealership sells
-- from it (GetVehicleCatalog), the vehicle wizard picks from it, and the garages, the Banks page, car claims and the
-- Director read its names and classes.
--
-- FROM THE LIST, KEPT IN THE DATABASE. server/vehicle_catalog_list.lua (it loads after this file) is the cars whip
-- ships. Each start adds the ones the `vehicle_catalog` table has never had and fills in a missing name or class; a
-- row that exists otherwise keeps what it has.
--
-- THE PICTURE IS THE FILE: img/vehicles/<model>.webp in its media pack, and not empty, read from disk at each
-- start. An older database also has the columns a retired in-game picture tool wrote (hasImage, imageW, imageH,
-- status, capturedBy, captureNote, generatedAt). Nothing reads them.

VehicleCatalog = {
    rows = {},   -- [model] = { model, displayName, class, hasImage }
    seed = {},   -- { model, class, name } lines, from server/vehicle_catalog_list.lua
}

local IMG_DIR = 'img/vehicles/'
local IMG_EXT = '.webp'

-- The list's class names, numbered as GetVehicleClass numbers them (the names client/vehicle_hud.lua uses).
local CLASS = {
    compacts = 0, sedans = 1, suvs = 2, coupes = 3, muscle = 4, sportsclassics = 5, sports = 6, super = 7,
    motorcycles = 8, offroad = 9, industrial = 10, utility = 11, vans = 12, cycles = 13, boats = 14,
    helicopters = 15, planes = 16, service = 17, emergency = 18, military = 19, commercial = 20, trains = 21,
    openwheel = 22,
}

local SEED_CHUNK = 500     -- list rows to one INSERT
local OPENS_A_TICK = 500   -- picture files opened before a pause (a slow disk must not hold the main thread)

function VehicleCatalog.ensureTable()
    return CreateTable('vehicle_catalog', [[
        CREATE TABLE IF NOT EXISTS `vehicle_catalog` (
            `model`       VARCHAR(60) NOT NULL,
            `displayName` VARCHAR(64) DEFAULT NULL,
            `class`       TINYINT     DEFAULT NULL,
            PRIMARY KEY (`model`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
end

--- Put the list's cars into the table: models it has never had, and a name or class for rows missing one.
---@return number added  rows written
local function addFromList()
    local todo, seen = {}, {}
    for _, e in ipairs(VehicleCatalog.seed) do
        local model = type(e[1]) == 'string' and e[1]:lower() or ''
        local class = CLASS[tostring(e[2] or ''):lower()]
        local name = type(e[3]) == 'string' and e[3] ~= '' and e[3]:sub(1, 64) or nil
        if model == '' or #model > 60 or not class then
            print(('^3[whip_core:vehicles] server/vehicle_catalog_list.lua: the line { %q, %q } has no model or no'
                .. ' class whip knows; it was left out^0'):format(tostring(e[1]), tostring(e[2])))
        elseif not seen[model] then
            seen[model] = true
            local row = VehicleCatalog.rows[model]
            if not row or row.class == nil or (row.displayName == nil and name) then
                todo[#todo + 1] = { model = model, class = class, name = name }
            end
        end
    end

    local added = 0
    for first = 1, #todo, SEED_CHUNK do
        local marks, args = {}, {}
        local last = math.min(first + SEED_CHUNK - 1, #todo)
        for i = first, last do
            marks[#marks + 1] = '(?,?,?)'
            args[#args + 1] = todo[i].model
            args[#args + 1] = todo[i].name
            args[#args + 1] = todo[i].class
        end
        local ok, err = pcall(MySQL.query.await, ([[
            INSERT INTO `vehicle_catalog` (`model`, `displayName`, `class`) VALUES %s
            ON DUPLICATE KEY UPDATE
                `displayName` = COALESCE(`displayName`, VALUES(`displayName`)),
                `class`       = COALESCE(`class`, VALUES(`class`))
        ]]):format(table.concat(marks, ',')), args)
        if ok then
            for i = first, last do
                local t = todo[i]
                local row = VehicleCatalog.rows[t.model] or { model = t.model }
                row.displayName = row.displayName or t.name
                row.class = row.class or t.class
                VehicleCatalog.rows[t.model] = row
                added = added + 1
            end
        else
            print(('^1[whip_core:vehicles] ERROR adding the vehicle list to the catalog: %s^0'):format(tostring(err)))
        end
    end
    return added
end

--- Mark each row with whether its picture is on disk. Opened, never read.
---@return number pictured
local function findPictures()
    local roots = {}
    for _, res in ipairs(WhipAssets.resources()) do
        local root = GetResourceState(res) ~= 'missing' and GetResourcePath(res) or nil
        if root and root ~= '' then roots[res] = root end
    end

    local models = {}
    for model in pairs(VehicleCatalog.rows) do models[#models + 1] = model end
    local pictured, noPack = 0, nil
    for i, model in ipairs(models) do
        if i % OPENS_A_TICK == 0 then Wait(0) end
        local row = VehicleCatalog.rows[model]
        local path = IMG_DIR .. model .. IMG_EXT
        local res = WhipAssets.resourceFor(path)
        local root = res and roots[res]
        if res and not root then noPack = res end
        local f = row and root and io.open(root .. '/' .. path, 'rb')
        local onDisk = false
        if f then
            onDisk = (f:seek('end') or 0) > 0
            f:close()
        end
        if row then
            row.hasImage = onDisk
            if onDisk then pictured = pictured + 1 end
        end
    end
    if noPack then
        print(('^3[whip_core:vehicles] WARNING: there is no %s, so no car has a picture and the dealership has nothing'
            .. ' to sell^0'):format(noPack))
    end
    return pictured
end

--- Read the table, add the list, find the pictures. false: the read failed, and start-up halts (player_lifecycle.lua).
function VehicleCatalog.loadAll()
    local ok, rows = pcall(MySQL.query.await, 'SELECT `model`, `displayName`, `class` FROM `vehicle_catalog`', {})
    if not ok then
        print(('[whip_core:vehicles] ERROR loading the vehicle catalog: %s'):format(tostring(rows)))
        return false
    end

    VehicleCatalog.rows = {}
    for _, row in ipairs(rows or {}) do
        local model = tostring(row.model):lower()
        VehicleCatalog.rows[model] = { model = model, displayName = row.displayName, class = tonumber(row.class) }
    end

    addFromList()
    findPictures()
    return true
end

-- ============================================
-- Exports
-- ============================================

--- The URL a model's picture is served at, from any resource's NUI. false (never nil: an export's return list is cut at
--- the first nil) when no media pack holds vehicle pictures.
---@param key string  lower-case model
---@return string|false
local function imageUrl(key)
    return WhipAssets.url(IMG_DIR .. key .. IMG_EXT) or false
end

--- A row's picture: an add-on pack's own (RegisterVehicles), else the media packs' file. nil when it has none.
local function pictureOf(key, row)
    if row and row.addonImage then return row.addonImage end
    if row and row.hasImage == true then return imageUrl(key) or nil end
    return nil
end

-- ============================================
-- Add-on cars from other resources (RegisterVehicles)
-- ============================================
--
-- A car pack's cars, in the catalog while the pack runs: named, classed and pictured everywhere the catalog is read
-- (the dealership, the vehicle wizard, garages, the Banks page), with no edit to whip_core or the media packs. A model
-- whip already lists keeps its name and class and takes the pack's picture. Gone when the pack stops.
local addonCars = Registry.new('AddonVehicle', {
    label = 'add-on vehicle',
    onAdd = function(model, a)
        local row = VehicleCatalog.rows[model]
        if not row then
            row = { model = model, addonOnly = true }
            VehicleCatalog.rows[model] = row
        end
        row.displayName = row.displayName or a.displayName
        row.class = row.class or a.class
        row.addonImage = a.image
    end,
    onRemove = function(model)
        local row = VehicleCatalog.rows[model]
        if not row then return end
        if row.addonOnly then VehicleCatalog.rows[model] = nil else row.addonImage = nil end
    end,
})

--- Your resource's cars: the whole list (one you gave before and not now goes). Each { model, name, class, image? }:
--- class is one of the list's names ('sports', 'suvs', ...) or GetVehicleClass's number; image is a picture in your
--- resource ('img/mycar.webp', listed in your files {}), or '@another/img/x.webp'. true, or false and why (nothing is
--- added when any entry is refused).
exports('RegisterVehicles', function(list)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(list) ~= 'table' then return false, 'RegisterVehicles({ { model, name, class, image? }, ... })' end
    local read = {}
    for i, e in ipairs(list) do
        if type(e) ~= 'table' or type(e.model) ~= 'string' or e.model == '' or #e.model > 60 then
            return false, ('vehicle %d needs a model (60 characters at most)'):format(i)
        end
        local class = math.tointeger(tonumber(e.class)) or CLASS[tostring(e.class or ''):lower()]
        if not class or class < 0 or class > 22 then
            return false, ('vehicle "%s": class is one of sports, super, suvs, sedans, ... (or GetVehicleClass\'s number)'):format(e.model)
        end
        local image
        if e.image ~= nil then
            local why
            image, why = ResourceFileUrl(owner, e.image)
            if not image then return false, ('vehicle "%s": %s'):format(e.model, why) end
        end
        read[#read + 1] = { model = e.model:lower(), displayName = type(e.name) == 'string' and e.name:sub(1, 64) or nil,
                            class = class, image = image }
    end
    if not WaitForCoreReady() then return false, NOT_READY end
    -- Every model's owner first, so a clash changes nothing: not this list, not the one given before.
    for _, a in ipairs(read) do
        local by = addonCars:get(a.model) ~= nil and addonCars:ownerOf(a.model) or nil
        if by and by ~= owner and Registry.alive(by) then
            local why = ('add-on vehicle "%s" belongs to %s'):format(a.model, by)
            Registry.sayRefused(owner, why)
            return false, why
        end
    end
    local keep = {}
    for _, a in ipairs(read) do keep[a.model] = true end
    for _, key in ipairs(addonCars:keysOf(owner)) do
        if not keep[key] then addonCars:remove(owner, key) end
    end
    for _, a in ipairs(read) do
        local ok, why = addonCars:add(owner, a.model, a)
        if not ok then return false, why end
    end
    return true
end)

--- The picture's URL, or nil (a lookup: nil on a miss, like GetVehicle). The catalog's `image` field stays false.
---@param model string
---@return string|nil
exports('GetVehicleImage', function(model)
    if type(model) ~= 'string' then return nil end
    local key = model:lower()
    return pictureOf(key, VehicleCatalog.rows[key])
end)

---@param model string
---@return boolean
exports('HasVehicleImage', function(model)
    if type(model) ~= 'string' then return false end
    local key = model:lower()
    return pictureOf(key, VehicleCatalog.rows[key]) ~= nil
end)

--- The whole catalog, a copy: model -> { model, displayName, class, hasImage, image, inGame }. `image` is the picture's
--- URL, or false. `inGame` is whether this game has the model (Vehicles.modelExists): false for one it does not (an
--- add-on car whose resource is gone), nil while no player's game has said. A seller leaves `inGame == false` out.
---@return table
exports('GetVehicleCatalog', function()
    local out = {}
    for key, row in pairs(VehicleCatalog.rows) do
        local picture = pictureOf(key, row)
        out[key] = {
            model       = key,
            displayName = row.displayName,
            class       = row.class,
            hasImage    = picture ~= nil,
            image       = picture or false,
            inGame      = Vehicles.modelExists(key),
        }
    end
    return out
end)
