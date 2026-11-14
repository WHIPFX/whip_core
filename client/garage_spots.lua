-- ============================================
-- GARAGE SPOTS — Client
-- Parking bays, and the list you scroll in one.
-- ============================================
--
-- The bay you are standing in is the interface: press E on an empty bay and the prompt itself becomes
-- the list of cars parked there (the same circle, scroll and E), and the one you pick appears in it.
--
-- One garage, many bays. A spot belongs to a garage and adds nothing but a place, so a car park is
-- one garage with thirty ways in rather than thirty garages. The garage still owns the vehicles,
-- the name and the blip; see server/garage_spots.lua.
--
-- The flow:
--
--   COLLAPSED   one option, the garage's name (asking the server on approach would be a round
--               trip for every bay you walk past in a car park).
--   EXPANDED    press E, the server answers, and Interactions.setOptions replaces that one option
--               with one per car. Scrolling is the interaction system's, not this file's.
--   PICK        E on a car asks the server to retrieve it INTO THIS BAY.
--   COLLAPSE    look away or walk off and it folds back up, via the onBlur hook. Leaving is the
--               cancel.
--
-- An occupied bay has no prompt at all (there is nowhere to put a car). What you get instead is a
-- Store option on the car itself, which empties the bay and brings this one back.

local spots = {}          -- [spotId] = spot record from the server
local prompts = {}        -- [spotId] = interaction id
local expanded = {}       -- [spotId] = true while showing the vehicle list

--- How close a vehicle has to be to count as parked in a bay.
local function spotRadius()
    return Config.GarageSpotRadius or 3.5
end

-- ============================================
-- Private garages
-- ============================================
--
-- A private garage (a property's: see "Private garages" in server/garages.lua) is for the people its
-- owner says; the server tells this client which ones are this character's. The bays of any other
-- are not offered at all (no prompt, no Store option, no outline). The server refuses them anyway.

local access = {}   -- [garageKey] = true for each private garage this character may use

RegisterNetEvent('whip_core:client:garageAccess', function(set)
    access = type(set) == 'table' and set or {}
end)

--- May this player use this garage? A public one always.
---
--- A bay can arrive before its garage does (two events), so a key shaped like a private one
--- (every private prefix has a ':' in it) is treated as private until the garage says otherwise.
---@param garageKey string
---@return boolean
function GarageUsable(garageKey)
    local g = Vehicles.getGarageDefs and Vehicles.getGarageDefs()[garageKey]
    local private = (g and g.private) or (not g and type(garageKey) == 'string' and garageKey:find(':', 1, true) ~= nil)
    if not private then return true end
    return access[garageKey] == true
end

-- ============================================
-- Occupancy
-- ============================================

-- [spotId] = true while something is parked in it. See the sweep below for why this is a cache
-- rather than a question asked on demand.
local occupied = {}
-- [spotId] = true while the only car in it is the one this player drives (the sweep; GarageSpotOccupancy).
local takenByMine = {}

--- The vehicle sitting in this bay, if any: one whose body overlaps the bay's outline (shared/garage_bay.lua).
---
--- Any vehicle counts, not just ones whip knows about (an abandoned taxi takes the space). The Store
--- option is the half that cares about ownership.
---
--- Not called from a prompt's condition (see `occupied`): it walks the whole vehicle pool.
--- A car model's half length and half width, from its box (asked once a model). nil, nil when it has no
--- box yet: GarageBay then takes a large car's.
---
--- Never smaller than the server's car: the server has no model sizes and takes every car as GarageBay's
--- large one, so a bay offered here is free there too. A bigger vehicle (a van, a bus) keeps its own box.
local _carHalf = {}   -- [model] = { hl, hw }
local function carHalfSize(model)
    local k = _carHalf[model]
    if k then return k[1], k[2] end
    local mn, mx = GetModelDimensions(model)
    if not mn or not mx or (mx.y - mn.y) <= 0.01 then return nil, nil end
    k = { math.max((mx.y - mn.y) * 0.5, GarageBay.CAR_HALF_LENGTH), math.max((mx.x - mn.x) * 0.5, GarageBay.CAR_HALF_WIDTH) }
    _carHalf[model] = k
    return k[1], k[2]
end

--- Keep the occupancy of nearby bays current.
---
--- A cache: the question is expensive and the answer slow-moving. Twice a second, only for bays within
--- interaction range plus slack (the shape the door and vehicle-part threads use).
CreateThread(function()
    while not PlayerLoaded do Wait(500) end

    -- Generous next to the ~5m the prompt is visible from, so a bay is already known to be free or
    -- taken by the time its circle could appear rather than resolving a beat later.
    local NEAR = 40.0
    local NEAR_SQ = NEAR * NEAR

    while true do
        local pos = GetEntityCoords(PlayerPedId())

        local near = {}
        for spotId, s in pairs(spots) do
            local dx, dy, dz = s.x - pos.x, s.y - pos.y, s.z - pos.z
            if (dx * dx + dy * dy + dz * dz) <= NEAR_SQ then
                near[#near + 1] = spotId
            else
                -- Forgotten rather than remembered as free: a bay across the map has no answer,
                -- and a stale `false` would let its prompt draw the moment you got near it.
                occupied[spotId] = nil
                takenByMine[spotId] = nil
            end
        end

        -- One walk of the vehicle pool per pass, not one per bay: the cars that could be in any of
        -- these bays are collected once, then each bay is tested against that short list.
        if #near > 0 then
            local r = spotRadius()
            local reachSq = (NEAR + r) * (NEAR + r)
            local cars = {}
            local driving = GetVehiclePedIsIn(PlayerPedId(), false)
            for _, veh in ipairs(GetGamePool('CVehicle')) do
                local c = GetEntityCoords(veh)
                local dx, dy, dz = c.x - pos.x, c.y - pos.y, c.z - pos.z
                if (dx * dx + dy * dy + dz * dz) <= reachSq then
                    local hl, hw = carHalfSize(GetEntityModel(veh))
                    cars[#cars + 1] = { c = c, h = GetEntityHeading(veh), hl = hl, hw = hw, mine = veh == driving }
                end
            end

            -- Taken when a car's body overlaps the bay's outline (shared/garage_bay.lua), not by a
            -- radius (side by side, that took the next bay too). Which bays ONLY the car this player
            -- drives takes is kept too, for the parking helper, by the same outline rule.
            for _, spotId in ipairs(near) do
                local s = spots[spotId]
                local taken, onlyMine = false, true
                for i = 1, #cars do
                    local k = cars[i]
                    if GarageBay.overlaps(s.x, s.y, s.z, s.heading, k.c.x, k.c.y, k.c.z, k.h, k.hl, k.hw) then
                        taken = true
                        if not k.mine then onlyMine = false break end
                    end
                end
                occupied[spotId] = taken
                takenByMine[spotId] = (taken and onlyMine) or nil
            end
        end

        Wait(500)
    end
end)

--- Which bay this vehicle is parked in, if any.
---
--- The other direction of the same question, per vehicle: what the Store option needs.
---
--- Only bays this player may use (GarageUsable): a car sitting in somebody's private garage is not
--- in a bay as far as this player is concerned, so it offers no Store and draws no outline.
---@param veh number|nil
---@return table|nil spot
function GarageSpotForVehicle(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    local c = GetEntityCoords(veh)
    local r = spotRadius()
    local rSq = r * r
    local best, bestSq = nil, rSq
    for _, s in pairs(spots) do
        local dx, dy, dz = c.x - s.x, c.y - s.y, c.z - s.z
        local d = dx * dx + dy * dy + dz * dz
        if d < bestSq and GarageUsable(s.garageKey) then best, bestSq = s, d end
    end
    return best
end

-- ============================================
-- Store, on a car's doors
-- ============================================
--
-- Put it away: only when the car is sitting in a parking bay (whose own prompt is gone while
-- something is in it). Storing empties the space and brings that prompt back.
--
-- On every door (not something you do from a particular side), last in the stack. Put there from
-- here, as a satellite would; its id stays 'store', so an admin's override on '<door>#store' finds it.
--
-- Not key-gated: a key in whip is an ITEM, not ownership. The server's rule is ownership (the
-- `vehicle` param resolver on garageSpotStore); a prompt refused with a reason beats one that never
-- appears.
--
-- And on a bike's, a bicycle's and a boat's one prompt, which stand in for a car's doors.
for _, door in ipairs({ 'door_dside_f', 'door_pside_f', 'door_dside_r', 'door_pside_r', 'bike', 'bicycle', 'boat' }) do
    local ok, why = VehiclePartOptions.add(GetCurrentResourceName(), door, {
        id    = 'store',
        icon  = 'store',
        label = 'Store Vehicle',
        can   = function(veh) return GarageSpotForVehicle(veh) ~= nil end,
        act   = function(veh)
            local spot = GarageSpotForVehicle(veh)
            if not spot then return end
            local vId = Vehicles.idFor(veh)
            -- A car whip does not know (a street car nobody has driven) is nobody's to store: said, not
            -- silent. Somebody else's car is refused by the server, which says so too.
            if not vId then UI.Notify('That is not your vehicle', 'error') return end
            TriggerServerEvent('whip_core:server:garageSpotStore', spot.spotId, vId)
        end,
    })
    if not ok then print(('[whip_core:garage] no Store on %s: %s'):format(door, tostring(why))) end
end

-- ============================================
-- The options a bay offers
-- ============================================

--- Forward-declared: collapsedOptions and the expand path call each other, and a local binds only
--- to code written after it.
local collapsedOptions, collapse

--- What a bay looks like before anybody has asked it anything.
---@param spot table
---@return table options
function collapsedOptions(spot)
    return { {
        id    = 'garage',
        icon  = 'garage',
        label = function()
            local g = Vehicles.getGarageDefs()[spot.garageKey]
            return (g and g.name) or 'Garage'
        end,
        callback = function()
            -- Nothing beyond the ask: the list arrives as an event (the garageSpotList handler), as
            -- a blocking callback would freeze the frame.
            expanded[spot.spotId] = true
            TriggerServerEvent('whip_core:server:garageSpotList', spot.spotId)
        end,
    } }
end

--- Fold a bay back to its single option.
---@param spotId number
function collapse(spotId)
    if not expanded[spotId] then return end
    expanded[spotId] = nil

    local id = prompts[spotId]
    local spot = spots[spotId]
    if id and spot and Interactions then
        Interactions.setOptions(id, collapsedOptions(spot))
    end
end

-- ============================================
-- Registration
-- ============================================

local function removeSpotPrompt(spotId)
    local id = prompts[spotId]
    if not id then return end
    if Interactions then Interactions.remove(id) end
    prompts[spotId] = nil
    expanded[spotId] = nil
    -- Cleared here too: the sweep only revisits spots that still exist.
    occupied[spotId] = nil
    takenByMine[spotId] = nil
end

local function addSpotPrompt(spot)
    if prompts[spot.spotId] then return end
    if not Interactions then return end

    local id = ('garage_spot_%d'):format(spot.spotId)

    Interactions.register({
        id    = id,
        -- Above the bay's floor (where the outline is drawn), at about eye level.
        x     = spot.x, y = spot.y, z = spot.z + (Config.GarageSpotPromptHeight or 1.22),
        group = 'garages',

        -- A billboard, not a sign: a bay is a patch of ground, read from wherever you walk up from.
        focusMode = 'near',

        options = collapsedOptions(spot),

        --- Gone while something is parked here. The car's own Store option is what you get instead.
        ---
        --- Reads the cached answer (see the sweep above). `nil` (not looked at yet) is treated as
        --- occupied.
        condition = function()
            return occupied[spot.spotId] == false and GarageUsable(spot.garageKey)
        end,

        --- Folded back up when you stop looking at it: leaving is the cancel.
        onBlur = function() collapse(spot.spotId) end,
    })

    prompts[spot.spotId] = id
end

--- Rebuild every prompt from the current spot set.
local function rebuildPrompts()
    for spotId in pairs(prompts) do removeSpotPrompt(spotId) end
    for _, s in pairs(spots) do addSpotPrompt(s) end
end

-- The prompt height changed in /whip → Settings: each bay's prompt is made again at the new height.
Settings.onChange('GarageSpotPromptHeight', rebuildPrompts)

--- Every known bay, keyed by spotId.
---
--- The same shape and purpose as Vehicles.getGarageDefs: the Garage Manager draws its list of bays from
--- what the client already holds.
---@return table  [spotId] = { spotId, garageKey, x, y, z, heading, label }
function GetGarageSpotDefs() return spots end

-- Is this bay known to be empty? Tri-state: `occupied[spotId]` is true (taken), false (looked at,
-- empty) or nil (too far away to have been looked at). For a prompt only `false` means empty (the
-- `== false` test in the prompt condition above).

--- The RAW tri-state, for callers that need to tell "empty" from "not looked at yet": nil as "taken"
--- is right for a PROMPT, wrong for a HINT (the outline would be missing exactly as a driver arrives).
---
--- Returns true (taken), false (empty), or nil (out of the sweep's reach, or not swept yet), and,
--- second, true when the only car taking it is the one this player is driving.
---@param spotId number
---@return boolean|nil taken
---@return boolean|nil onlyMine
function GarageSpotOccupancy(spotId)
    return occupied[spotId], takenByMine[spotId]
end

--- Let anything watching know the set changed.
---
--- The Garage Manager defines this global; this file only calls it if it exists, so the garage system
--- works identically with the tool file deleted (as doors.lua's DoorManagerOpen gate).
local function announceChange()
    if GarageSpotsChanged then GarageSpotsChanged() end
end

-- ============================================
-- Server sync
-- ============================================

RegisterNetEvent('whip_core:client:garageSpotsSync', function(list)
    spots = {}
    if type(list) == 'table' then
        for _, s in ipairs(list) do
            if s and s.spotId then spots[s.spotId] = s end
        end
    end
    rebuildPrompts()
    announceChange()
end)

RegisterNetEvent('whip_core:client:garageSpotCreated', function(spot)
    if not spot or not spot.spotId then return end
    spots[spot.spotId] = spot
    addSpotPrompt(spot)
    announceChange()
end)

--- A bay moved — the bay tool's save landing back on everyone.
---
--- The prompt is rebuilt, not patched (a prompt is registered at a position).
RegisterNetEvent('whip_core:client:garageSpotUpdated', function(spot)
    if not spot or not spot.spotId then return end

    removeSpotPrompt(spot.spotId)
    spots[spot.spotId] = spot
    addSpotPrompt(spot)

    -- The occupancy cache is keyed on the bay, and the bay just moved: whatever was parked in the
    -- old space is not in the new one. Forgotten rather than guessed, so the sweep answers fresh.
    occupied[spot.spotId] = nil
    takenByMine[spot.spotId] = nil

    announceChange()
end)

RegisterNetEvent('whip_core:client:garageSpotDeleted', function(spotId)
    removeSpotPrompt(spotId)
    spots[spotId] = nil
    announceChange()
end)

-- ============================================
-- Manufacturer logos
-- ============================================
--
-- GetMakeNameFromVehicleModel answers with a GXT label key ("VAPID", "DECLASSE"), which lowercases
-- straight onto the logo files from the game's mpcarhud dictionaries. The raw key, not GetLabelText
-- (localised). Cached per model.
local logoCache = {}     -- [model] = icon name
local logoWarned = {}    -- [make] = true, so an unknown brand is reported once and not per row

-- The makes' logos changed in /whip → Settings: every model is worked out again at the next list.
Settings.onChange('VehicleMakeLogos', function()
    logoCache = {}
    logoWarned = {}
end)

--- The badge icon for a vehicle model: its manufacturer's logo, or the generic car.
---
--- Falls back rather than guesses: a make with no logo gets the generic car icon (a missing file would
--- paint an empty disc).
---@param model string|number
---@return string icon
local function logoIconFor(model)
    if model == nil then return 'car' end

    local cached = logoCache[model]
    if cached then return cached end

    local hash = (type(model) == 'string') and GetHashKey(model) or model
    local icon = 'car'

    -- pcall'd: this native is documented as CRASHING on game builds at or below 1868.
    local ok, make = pcall(GetMakeNameFromVehicleModel, hash)
    if ok and make and make ~= '' and make ~= 'CARNOTFOUND' then
        local key = make:lower()
        -- The escape hatch for a label key that does not match its texture's filename (the game
        -- ships a logo spelled "emporer").
        key = (Config.VehicleMakeLogos or {})[key] or key

        if HasVehicleLogo and HasVehicleLogo(key) then
            icon = 'mfr_' .. key
        elseif not logoWarned[key] then
            -- Said once per unknown make: the list to paste into Config.VehicleMakeLogos.
            logoWarned[key] = true
            print(('[whip_core:garage] no logo for manufacturer "%s" (model %s) — using the generic car')
                :format(key, tostring(model)))
        end
    end

    logoCache[model] = icon
    return icon
end

--- The cars in this bay's garage, as a scrollable list.
---
--- Arrives as an event, so `expanded` is set on the keypress and checked here: the player may have
--- walked away meanwhile.
RegisterNetEvent('whip_core:client:garageSpotList', function(spotId, _, rows)
    if not expanded[spotId] then return end

    local spot = spots[spotId]
    local id = prompts[spotId]
    if not spot or not id then return end

    rows = rows or {}

    if #rows == 0 then
        -- Not silence, and not an empty list: say there is nothing in the garage.
        Interactions.setOptions(id, { {
            id    = 'empty',
            icon  = 'garage',
            label = 'Garage is empty',
            -- No callback: pressing E on it does nothing.
        } })
        return
    end

    local options = {}
    for i = 1, #rows do
        local row = rows[i]
        options[i] = {
            id    = 'veh_' .. tostring(row.vehicleId),
            -- The marque, so five cars read as five different cars at a glance.
            icon  = logoIconFor(row.model),

            -- And the car itself, above the text, for whichever row is highlighted: the capture
            -- tool's snapshots. A numeric name (a model whip could not resolve: the hash as a
            -- string) asks for no picture.
            image = (row.model and not tostring(row.model):match('^%-?%d+$'))
                    and ('img/vehicles/' .. tostring(row.model):lower() .. '.webp')
                    or nil,
            -- displayName comes from the vehicle catalog; the model name is the fallback (the
            -- panel's rule).
            label = ('%s  %s'):format(row.displayName or row.model or 'Vehicle', row.plate or ''),
            callback = function()
                TriggerServerEvent('whip_core:server:garageSpotRetrieve', spotId, row.vehicleId)
                -- Folded immediately: the car is about to appear in this bay anyway.
                collapse(spotId)
            end,
        }
    end

    Interactions.setOptions(id, options)
end)

-- Bays are set out with the one bay tool (/whip → Garages → a garage → Set out bays in the world, or a
-- wizard's Bays step: PropertyEditor.placeBays).
