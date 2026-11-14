-- ============================================
-- /whip SECTION — Ground Items (client wiring)
-- ============================================
--
-- The page's Lua half: the item cache, a pile's own blip and marker (and the marker's draw loop),
-- and the mutation callbacks. The player-facing ground pickup runtime is client/ground.lua; the grid
-- of squares on the ground is the /w Ground Items Debug's (tools/ground_debug.lua).
--
-- Every server event named here is UNCHANGED from the standalone tool — the server
-- never noticed the consolidation. gimClose (the old NUI close callback) did not move:
-- the shell owns focus and close now; leave fires the gimClosed viewer teardown.

-- State (moved from tools/ground.lua)
local gimBlips       = {}    -- [id] = blipHandle
local gimMarkers     = {}    -- [id] = { x, y, z }
local gimItemCache   = {}    -- [id] = { x, y, z, item }  -- local cache for teleport/blip/marker
local gimPageOpen    = false -- the Ground page is showing (its updates go to it only then)
-- The marker draw loop, started when there is something to draw; defined with it below.
local startMarkerLoop

--- Rebuild gimItemCache from NUI payload items array
local function gimUpdateCache(items)
    gimItemCache = {}
    if not items then return end
    if type(items) == 'table' then
        for _, item in ipairs(items) do
            if item and item.id then
                gimItemCache[item.id] = {
                    x = item.x or 0, y = item.y or 0, z = item.z or 0,
                    item = item.item or 'unknown',
                }
            end
        end
    end
end

--- Remove blips/markers for items that no longer exist
local function gimCleanupStale()
    for id, blip in pairs(gimBlips) do
        if not gimItemCache[id] then
            if DoesBlipExist(blip) then RemoveBlip(blip) end
            gimBlips[id] = nil
        end
    end
    for id in pairs(gimMarkers) do
        if not gimItemCache[id] then
            gimMarkers[id] = nil
        end
    end
end

--- Drop every blip and marker (Delete everything, and developer mode going off).
local function gimClearBlipsAndMarkers()
    for _, blip in pairs(gimBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    gimBlips = {}
    gimMarkers = {}
end

--- A pile's blip: a red dot named after the item and its id. One pile, picked out in red among the
--- Ground Items Debug's yellow ones.
local function gimAddBlip(id, cached)
    local blip = AddBlipForCoord(cached.x, cached.y, cached.z)
    SetBlipSprite(blip, 1)
    SetBlipColour(blip, 1)
    SetBlipScale(blip, 0.9)
    SetBlipAsShortRange(blip, false)
    local itemDef = Config.Items[cached.item]
    local name = itemDef and itemDef.name or cached.item
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(name .. ' #' .. id)
    EndTextCommandSetBlipName(blip)
    gimBlips[id] = blip
end

--- Anything of this page's still on the admin's map or in the world: a pile's blip or marker.
local function gimMarksOn()
    return next(gimBlips) ~= nil or next(gimMarkers) ~= nil
end

-- ============================================
-- Section lifecycle + data forward
-- ============================================

PanelSections['ground'] = {
    enter = function()
        gimPageOpen = true
        TriggerServerEvent('whip_core:server:gimGetAll')
    end,
    -- BLIPS AND MARKERS STAY when the menu closes, so the admin can go to the piles. While any
    -- blip or marker is on, the server keeps sending the list (gimRefresh, below), so a pile picked up
    -- loses its own. With none on, the page stops listening. They go when turned off here, and when
    -- developer mode goes off (GroundManagerOff). Every pile at once is the /w Ground Items Debug.
    leave = function()
        gimPageOpen = false
        if not gimMarksOn() then TriggerServerEvent('whip_core:server:gimClosed') end
    end,
}

--- Developer mode off, or dev tools taken back (tools/core.lua devtoolsOff): the blips and the markers
--- go, and the server stops sending the list. (The /w Ground Items Debug, grid and all, goes with the
--- other /w tools.)
function GroundManagerOff()
    gimClearBlipsAndMarkers()
    if not gimPageOpen then TriggerServerEvent('whip_core:server:gimClosed') end
end

--- Server sends all ground items -> forward as the section-enter snapshot.
--- cellSize rides along: JS shows the grid cell per item. So do the blips and markers this admin has
--- on (they survive leave too), and whether the /w Ground Items Debug is on: the page's chips show them.
RegisterNetEvent('whip_core:client:gimAllItems', function(data)
    gimUpdateCache(data.items)
    data.cellSize = Config.GroundItemCellSize or 50
    data.debugOn = DevToolActive('Ground Items Debug')
    local blipIds, markerIds = {}, {}
    for id in pairs(gimBlips) do blipIds[#blipIds + 1] = id end
    for id in pairs(gimMarkers) do markerIds[#markerIds + 1] = id end
    data.blipIds, data.markerIds = blipIds, markerIds
    WhipPanelData('ground', 'all', data)
end)

--- Server sends refresh data -> the blips follow it, and the page if it is showing.
RegisterNetEvent('whip_core:client:gimRefresh', function(data)
    gimUpdateCache(data.items)
    gimCleanupStale()
    if gimPageOpen then WhipPanelData('ground', 'refresh', data) end
end)

-- ============================================
-- NUI Callbacks (moved verbatim from tools/ground.lua)
-- ============================================

--- Teleport to ground item
RegisterNUICallback('gimTeleport', function(data, cb)
    local n = tonumber(data.id)
    local id = n and math.floor(n)
    local cached = id and gimItemCache[id]
    if cached then
        local ped = PlayerPedId()
        SetEntityCoords(ped, cached.x, cached.y, cached.z + 1.0, false, false, false, true)
    end
    cb('ok')
end)

--- Toggle blip for a single ground item
RegisterNUICallback('gimToggleBlip', function(data, cb)
    local n = tonumber(data.id)
    local id = n and math.floor(n)
    if not id then cb('ok') return end

    if gimBlips[id] then
        if DoesBlipExist(gimBlips[id]) then RemoveBlip(gimBlips[id]) end
        gimBlips[id] = nil
    else
        local cached = gimItemCache[id]
        if cached then gimAddBlip(id, cached) end
    end
    cb({ on = gimBlips[id] ~= nil })   -- the page says whether it is on
end)

--- Toggle marker for a single ground item
RegisterNUICallback('gimToggleMarker', function(data, cb)
    local n = tonumber(data.id)
    local id = n and math.floor(n)
    if not id then cb('ok') return end

    if gimMarkers[id] then
        gimMarkers[id] = nil
    else
        local cached = gimItemCache[id]
        if cached then
            gimMarkers[id] = { x = cached.x, y = cached.y, z = cached.z }
            startMarkerLoop()
        end
    end
    cb({ on = gimMarkers[id] ~= nil })
end)

--- The /w Ground Items Debug, on or off from the page (tools/ground_debug.lua): every pile marked to
--- the sky and on the map in yellow. The same tool as its /w row, so either place turns it off.
RegisterNUICallback('gimDebug', function(_, cb)
    local name = 'Ground Items Debug'
    cb({ on = SetDevTool(name, not DevToolActive(name)) })
end)

--- Delete a ground item
RegisterNUICallback('gimDeleteItem', function(data, cb)
    local n = tonumber(data.id)
    local id = n and math.floor(n)
    if id then
        TriggerServerEvent('whip_core:server:gimDeleteItem', id)
        -- Clean up local blip/marker
        if gimBlips[id] then
            if DoesBlipExist(gimBlips[id]) then RemoveBlip(gimBlips[id]) end
            gimBlips[id] = nil
        end
        gimMarkers[id] = nil
    end
    cb('ok')
end)

--- Delete the piles picked in the list, in one go
RegisterNUICallback('gimDeleteItems', function(data, cb)
    local ids = {}
    for _, v in ipairs(type(data) == 'table' and type(data.ids) == 'table' and data.ids or {}) do
        local id = tonumber(v)
        if id then
            id = math.floor(id)
            ids[#ids + 1] = id
            if gimBlips[id] then
                if DoesBlipExist(gimBlips[id]) then RemoveBlip(gimBlips[id]) end
                gimBlips[id] = nil
            end
            gimMarkers[id] = nil
        end
    end
    if #ids > 0 then TriggerServerEvent('whip_core:server:gimDeleteItems', ids) end
    cb('ok')
end)

--- Delete all ground items
RegisterNUICallback('gimDeleteAll', function(_, cb)
    TriggerServerEvent('whip_core:server:gimDeleteAll')
    gimClearBlipsAndMarkers()
    cb('ok')
end)

--- Delete ground items in current grid cell
RegisterNUICallback('gimDeleteCell', function(_, cb)
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local cellSize = Config.GroundItemCellSize or 50
    local cellKey = math.floor(c.x / cellSize) .. '_' .. math.floor(c.y / cellSize)
    TriggerServerEvent('whip_core:server:gimDeleteCell', cellKey)
    -- Clean up local blips/markers for the items IN THIS CELL only. An item the cache cannot place is
    -- left alone.
    for id, cached in pairs(gimItemCache) do
        local x, y = tonumber(cached.x), tonumber(cached.y)
        if x and y and (math.floor(x / cellSize) .. '_' .. math.floor(y / cellSize)) == cellKey then
            local blip = gimBlips[id]
            if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
            gimBlips[id] = nil
            gimMarkers[id] = nil
        end
    end
    cb({ cellKey = cellKey })
end)

-- (The grid of squares is the /w Ground Items Debug's now: tools/ground_debug.lua, "The grid".)

local markerLoopRunning = false

-- ============================================
-- Marker Draw Thread — tall red column for marked items (moved verbatim)
-- ============================================

local function markerLoop()
    while true do
        if next(gimMarkers) then
            for _, pos in pairs(gimMarkers) do
                DrawMarker(
                    1,                          -- type: cylinder
                    pos.x, pos.y, pos.z + 50.0, -- position (center raised 50 units)
                    0.0, 0.0, 0.0,              -- direction
                    0.0, 0.0, 0.0,              -- rotation
                    1.0, 1.0, 100.0,            -- scale (1m wide, 100m tall)
                    255, 50, 50, 120,           -- RGBA (red, semi-transparent)
                    false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false
                )
            end
            Wait(0)
        else
            break
        end
    end
    markerLoopRunning = false
end

startMarkerLoop = function()
    if markerLoopRunning then return end
    markerLoopRunning = true
    CreateThread(markerLoop)
end
