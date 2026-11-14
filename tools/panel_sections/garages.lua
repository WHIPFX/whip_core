-- ============================================
-- /whip SECTION — Garages (client wiring)
-- ============================================
--
-- Replaces tools/garage_manager.lua. The mutation callbacks (gmCreateGarage,
-- gmUpdateGarage, gmDeleteGarage, gmMoveVehicle, gmGetGarageVehicles, gmGetPlayerPos,
-- gmTeleportGarage) moved here verbatim; gmClose and ToolHandlers['Garages'] retired
-- with the standalone overlay — the shell owns focus and the close funnel now.
--
-- The old gmAllGarages handler branched on "already open" to refresh instead of
-- re-open. That branch collapses here: every response forwards as 'all' and the
-- section adopts idempotently (keeps the edit in progress, backs out only if the
-- edited garage vanished server-side).

-- ============================================
-- Parking spots
-- ============================================
--
-- THE BAYS ARE ALREADY ON THIS CLIENT. Every spot is synced to every player because the prompts are
-- built from them (client/garage_spots.lua), so the manager reads them out of memory rather than
-- asking the server for a list it was handed at login. Creating and deleting still go to the
-- server, ACE-gated, because those are writes.
--
-- WHICH GARAGE IS SELECTED lives here rather than only in the NUI, because the marker thread below
-- needs it too.
local gmSelectedGarage = nil

-- IS ANYBODY LOOKING? The panel builds a section's DOM the first time the panel is OPENED, but the
-- shell delivers data to any registered section whenever it arrives — so a push before the first
-- open lands in a handler whose elements do not exist yet.
--
-- That is not hypothetical: bay counts are pushed whenever the spot set changes, and the set is
-- synced at login, which is about as far from "the panel is open" as it gets. The NUI now guards
-- itself as well, but not sending to a closed panel is the half that is actually correct — the
-- other half is only damage control.
local gmOpen = false

--- Hand the NUI the bays belonging to the selected garage.
---
--- Sorted by id so the list does not reshuffle itself on every refresh — pairs() order over the
--- spot table is arbitrary, and a list that reorders under the cursor is a list you cannot reliably
--- click a Delete button in.
local function pushSpots()
    if not gmOpen then return end
    local out = {}
    if gmSelectedGarage then
        local defs = Vehicles.getGarageDefs and Vehicles.getGarageDefs() or {}
        local g = defs[gmSelectedGarage]

        for _, s in pairs(GetGarageSpotDefs and GetGarageSpotDefs() or {}) do
            if s.garageKey == gmSelectedGarage then
                -- How far the bay is from the garage's own marker — the figure that tells an admin
                -- whether they have placed it where they think they have.
                local dist = nil
                if g and g.x then
                    local dx, dy, dz = s.x - g.x, s.y - g.y, s.z - g.z
                    dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                end
                out[#out + 1] = {
                    spotId = s.spotId, x = s.x, y = s.y, z = s.z,
                    heading = s.heading, dist = dist,
                }
            end
        end
        table.sort(out, function(a, b) return a.spotId < b.spotId end)
    end

    WhipPanelData('garages', 'spots', { garageKey = gmSelectedGarage, spots = out })
end

--- How many bays each garage has, keyed by garage key.
---
--- SENT WITH THE LIST BECAUSE IT IS THE FIRST THING WORTH KNOWING. A garage with no bays cannot be
--- reached at all — bays are the only way in — and until this went on the list, such a garage looked
--- exactly like a working one.
local function spotCounts()
    local counts = {}
    for _, s in pairs(GetGarageSpotDefs and GetGarageSpotDefs() or {}) do
        counts[s.garageKey] = (counts[s.garageKey] or 0) + 1
    end
    return counts
end

--- Push the bay COUNTS again, for the list's "unreachable" flag.
---
--- Separate from pushSpots because the two answer different questions for different panes: the
--- list needs every garage's count whether or not it is selected, and the detail pane needs one
--- garage's bays in full. Adding or deleting a bay changes both.
local function pushCounts()
    if not gmOpen then return end
    WhipPanelData('garages', 'counts', { spotCounts = spotCounts() })
end

--- Called by client/garage_spots.lua whenever the set changes. Global on purpose — that file looks
--- this name up and skips it when the tool is not loaded, so the garage system carries no knowledge
--- of the dev tool.
function GarageSpotsChanged()
    -- Counts always: the list flags every bay-less garage, selected or not.
    pushCounts()
    if gmSelectedGarage then pushSpots() end
end

PanelSections['garages'] = {
    enter = function()
        gmOpen = true
        TriggerServerEvent('whip_core:server:gmGetAllGarages')
    end,
    leave = function()
        gmOpen = false
        gmSelectedGarage = nil
        TriggerServerEvent('whip_core:server:gmClosed')
    end,
}

-- ============================================
-- Bay markers while the section is open
-- ============================================
--
-- SO YOU CAN SEE WHAT YOU ARE EDITING. A bay is an invisible patch of ground: its prompt only
-- appears when you are nearly standing in it, and not at all while it is occupied — which is
-- exactly when you are most likely to be wondering where it was. Drawn only while the Garages
-- section is open and only for the garage being edited, so it costs nothing the rest of the time.
--
-- And the thread only lives that long too: started when one is selected (below).
local markersRunning = false

local function markers()
    while gmSelectedGarage do
        local sleep = 500

        local pos = GetEntityCoords(PlayerPedId())
        -- Not under the bay tool (an in-world mode suspends the panel): it draws the bays itself, where they are
        -- going, and these would sit where they were.
        for _, s in pairs(not PropertyEditorActive and GetGarageSpotDefs and GetGarageSpotDefs() or {}) do
            if s.garageKey == gmSelectedGarage then
                local dx, dy, dz = s.x - pos.x, s.y - pos.y, s.z - pos.z
                if (dx * dx + dy * dy + dz * dz) < (120.0 * 120.0) then
                    sleep = 0
                    -- A flat square sized to the bay's own radius, so what is drawn is
                    -- literally the area that counts as occupied.
                    local r = (Config.GarageSpotRadius or 3.5) * 2.0
                    DrawMarker(1, s.x, s.y, s.z - 0.95,
                        0, 0, 0, 0, 0, 0, r, r, 0.4,
                        0, 200, 120, 120, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                end
            end
        end

        Wait(sleep)
    end
    markersRunning = false
end

RegisterNetEvent('whip_core:client:gmAllGarages', function(garages, vehicleCounts)
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    WhipPanelData('garages', 'all', {
        garages = garages,
        vehicleCounts = vehicleCounts,
        spotCounts = spotCounts(),
        pos = { x = c.x, y = c.y, z = c.z, h = GetEntityHeading(ped) },
    })
end)

RegisterNetEvent('whip_core:client:gmGarageVehicles', function(garageKey, vehicles)
    WhipPanelData('garages', 'vehicles', { garageKey = garageKey, vehicles = vehicles })
end)

-- ---- mutations (moved verbatim from tools/garage_manager.lua) ----

RegisterNUICallback('gmCreateGarage', function(data, cb)
    TriggerServerEvent('whip_core:server:gmCreateGarage', data)
    cb('ok')
end)

RegisterNUICallback('gmUpdateGarage', function(data, cb)
    TriggerServerEvent('whip_core:server:gmUpdateGarage', data.key, data)
    cb('ok')
end)

-- `moveTo`: where its cars go, the garage the admin chose (the server refuses a garage with cars in it without one).
RegisterNUICallback('gmDeleteGarage', function(data, cb)
    TriggerServerEvent('whip_core:server:gmDeleteGarage', data.key, data.moveTo)
    cb('ok')
end)

RegisterNUICallback('gmMoveVehicle', function(data, cb)
    TriggerServerEvent('whip_core:server:gmMoveVehicle', data.vehicleId, data.toGarageKey)
    cb('ok')
end)

RegisterNUICallback('gmGetGarageVehicles', function(data, cb)
    -- Selecting a garage in the list is also what selects it for the spot pane and the markers.
    -- Piggy-backed on this callback rather than given one of its own: the NUI already fires it on
    -- every selection, and a second message saying the same thing is a second thing to keep in step.
    gmSelectedGarage = data.garageKey
    if gmSelectedGarage and not markersRunning then
        markersRunning = true
        CreateThread(markers)
    end
    pushSpots()
    TriggerServerEvent('whip_core:server:gmGetGarageVehicles', data.garageKey)
    cb('ok')
end)

-- ---- parking spots ----

RegisterNUICallback('gmTeleportSpot', function(data, cb)
    local s = (GetGarageSpotDefs and GetGarageSpotDefs() or {})[tonumber(data and data.spotId) or -1]
    if s then
        local ped = PlayerPedId()
        SetEntityCoords(ped, s.x, s.y, s.z, false, false, false, true)
        SetEntityHeading(ped, s.heading or 0.0)
    end
    cb('ok')
end)

RegisterNUICallback('gmGetPlayerPos', function(_, cb)
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    cb({ x = c.x, y = c.y, z = c.z, h = GetEntityHeading(ped) })
end)

RegisterNUICallback('gmTeleportGarage', function(data, cb)
    local defs = Vehicles.getGarageDefs and Vehicles.getGarageDefs() or {}
    local g = defs[data.garageKey]
    if g then
        local ped = PlayerPedId()
        SetEntityCoords(ped, g.x, g.y, g.z, false, false, false, true)
        SetEntityHeading(ped, g.heading or 0.0)
    end
    cb('ok')
end)

-- ============================================
-- The garage wizard
-- ============================================
--
-- html/js/wp/garages.js's + New Garage: Name, Bays, Map, Create — and a garage's page, whose Change opens the same
-- wizard filled in with it. The calls:
--
--   gwPlaceBays  SET OUT THE BAYS, in the world: the one bay tool (PropertyEditor.placeBays, tools/property_editor.lua
--                — every garage's). Nothing is saved here: the bays go back to the wizard's draft (WhipPanelData
--                'wizBays'), a saved garage's with their spotIds (`id`), and only Create or Save writes them.
--   gwCreate     A NEW GARAGE AND ITS BAYS, at once: the server's whip_core:gmWizardCreate (server/devtools.lua),
--                which leashes every bay and the marker to where the admin stands (Config.GarageWizardReach).
--   gwSave       A SAVED GARAGE'S CHANGES, at once: whip_core:gmWizardSave — what changed only; a moved marker or bay
--                leashed the same way.

local GW_MAX_BAYS = 40       -- server/devtools.lua says the same

RegisterNUICallback('gwPlaceBays', function(data, cb)
    if PropertyEditor.isActive() then cb({ ok = false, why = 'Another in-world editor is open' }) return end
    local name = type(data) == 'table' and type(data.name) == 'string' and data.name ~= '' and data.name or 'New garage'
    -- The bays so far, carried in and out: setting more out later adds to them, and moves or takes away any. A saved
    -- bay's id goes through, so a move stays that bay.
    local started = PropertyEditor.placeBays({
        name = name, max = GW_MAX_BAYS,
        bays = type(data) == 'table' and type(data.bays) == 'table' and data.bays or {},
        onDone = function(bays)
            local out = {}
            for i, b in ipairs(bays) do out[i] = { x = b.x, y = b.y, z = b.z, heading = b.heading, id = b.id } end
            WhipPanelData('garages', 'wizBays', { bays = out })
        end,
    })
    cb(started and { ok = true } or { ok = false, why = 'The bay tool could not open' })
end)

--- The wizard's Save, for a garage that exists: what changed (server/devtools.lua, gmWizardSave).
RegisterNUICallback('gwSave', function(data, cb)
    CreateThread(function()
        local res = Callback('whip_core:gmWizardSave', data)
        cb(type(res) == 'table' and res or { ok = false, why = 'No answer from the server' })
    end)
end)

--- The wizard's Create: the server makes the garage and its bays (server/devtools.lua, gmWizardCreate).
RegisterNUICallback('gwCreate', function(data, cb)
    CreateThread(function()
        local res = Callback('whip_core:gmWizardCreate', data)
        cb(type(res) == 'table' and res or { ok = false, why = 'No answer from the server' })
    end)
end)

--- Go to a bay of the draft (the Bays step's Teleport), facing the way it does.
RegisterNUICallback('gwTeleport', function(data, cb)
    local x, y, z = tonumber(data and data.x), tonumber(data and data.y), tonumber(data and data.z)
    if x and y and z then
        local ped = PlayerPedId()
        SetEntityCoords(ped, x, y, z, false, false, false, true)
        SetEntityHeading(ped, tonumber(data.heading) or 0.0)
    end
    cb('ok')
end)
