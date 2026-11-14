-- ============================================
-- Dev Tools — Zone Manager + Zone Editor + Room Scanner
--              + Door Manager + Door Editor
-- ============================================

-- ============================================
-- Zone Manager — NUI Callbacks
-- ============================================

RegisterNUICallback('zmTeleportToZone', function(data, cb)
    local allZones = GetAllZones()
    for _, z in ipairs(allZones) do
        if z.id == data.id and z.pos then
            SetEntityCoords(PlayerPedId(), z.pos.x, z.pos.y, z.pos.z, false, false, false, false)
            break
        end
    end
    cb('ok')
end)

RegisterNUICallback('zmToggleDebug', function(data, cb)
    -- Find zone's current debug state and toggle it
    local allZones = GetAllZones()
    for _, z in ipairs(allZones) do
        if z.id == data.id then
            Zones.setDebug(data.id, not z.debug)
            break
        end
    end
    SendNUIMessage({ action = 'zmRefresh', zones = GetAllZones() })
    cb('ok')
end)

-- The list is redrawn when the delete arrives, not after a fixed wait: on a high ping the server's broadcast can
-- land later. A delete not heard of in 5 s redraws anyway (refused, or lost).
local _deletePending = nil   -- { id, deadline } while a saved zone's delete is out

AddEventHandler('whip_core:client:zoneDbDeleted', function(id)
    if not (_deletePending and _deletePending.id == id) then return end
    _deletePending = nil
    -- After client/zones.lua's own handler has taken it out of the list
    CreateThread(function()
        Wait(0)
        SendNUIMessage({ action = 'zmRefresh', zones = GetAllZones() })
    end)
end)

RegisterNUICallback('zmDeleteZone', function(data, cb)
    if data.id then
        -- DB zones: delete from DB via server event (which broadcasts deletion to all clients)
        if data.id:find('^dbzone_') then
            local pending = { id = data.id }
            _deletePending = pending
            TriggerServerEvent('whip_core:server:zeDeleteZone', data.id)
            CreateThread(function()
                Wait(5000)
                if _deletePending == pending then
                    _deletePending = nil
                    SendNUIMessage({ action = 'zmRefresh', zones = GetAllZones() })
                end
            end)
            cb('ok')
            return
        end
        -- Memory-only zones: just remove client-side
        Zones.remove(data.id)
    end
    SendNUIMessage({ action = 'zmRefresh', zones = GetAllZones() })
    cb('ok')
end)

-- The zones wizard's Save (zwUpdate) is the one way the page changes a zone.

RegisterNUICallback('zmToggleAllDebug', function(data, cb)
    local allZones = GetAllZones()
    for _, z in ipairs(allZones) do
        Zones.setDebug(z.id, data.enabled)
    end
    SendNUIMessage({ action = 'zmRefresh', zones = GetAllZones() })
    cb('ok')
end)

-- (zmCloseZoneManager retired with the standalone panel — the /whip shell owns close.)

-- ============================================
-- Zone Editor — State
-- ============================================

local zeActive      = false
local zeCam         = nil
local zeVelocity    = vector3(0, 0, 0)
local startZeLoop   -- the editor's input loop, started by EnterZoneEditor; defined with it below
local zeSpeed       = 1.0
local zeMode        = 'none'     -- 'none','box','sphere','poly'
local zeCreating    = false
local zeSelected    = nil
local zeDraftSizeX  = 10.0
local zeDraftSizeY  = 10.0
local zeDraftSizeZ  = 5.0
local zeDraftRadius = 10.0
local zeDraftMinZ   = nil
local zeDraftMaxZ   = nil
local zePolyPoints  = {}
local zePolyClosed  = false
local zeLabelVis    = true

-- DRAWING FOR THE WIZARD. The /whip Zones wizard opens this editor to draw ONE shape
-- (zwDraw, below): { shape = 'box'|'sphere'|'poly'|'scan' } while it does. The shape finished goes
-- back to the wizard (zeCreate → WhipPanelData 'shape') instead of being saved here, the editor
-- closes, and the wizard saves the zone whole — name, rules and all — when it is told to.
local zeCapture     = nil
-- MOVING A POLYGON'S CORNERS for the wizard (zwAdjust, below): { points, minZ, maxZ, carry, carryFrom }.
---@class ZoneAdjust
---@field points table[]
---@field minZ number
---@field maxZ number
---@field carry integer|nil
---@field carryFrom { x: number, y: number }|nil

---@type ZoneAdjust|nil
local zeAdjust      = nil

-- Vertex Editor state
---@type false|'position'|'height'
local zeVertexMode    = false
local zeVertexIndex   = nil
local zeVertexOriginal = nil
local zeVertexKeyPressed = false
local zeHeightKeyPressed = false

-- Room Scanner state
local rsScanActive    = false
local rsScanning      = false
local rsPreview       = false
local rsAllHitPoints  = {}
local rsSimplified    = {}
local rsMinZ          = nil
local rsMaxZ          = nil
local rsLastBurstPos  = nil
local rsBurstOrigin   = nil
local rsFadeLines     = {}
local rsRayCount      = 72
local rsMaxRange      = 20.0
local rsEpsilon       = 0.3
local rsBurstIndex    = 0
local rsBurstActive   = false
local RS_BURST_DIST   = 2.0
local RS_RAYS_PER_FRAME = 4
local RS_FADE_TIME    = 0.5
local rsReset                     -- forward declaration

-- Movement constants
local ZE_MOVE_SPEED = 30.0
local ZE_FAST_MULT  = 3.0
local ZE_SENSITIVITY = 5.0
local ZE_DAMPING    = 8.0
local ZE_SPEED_MIN  = 0.1
local ZE_SPEED_MAX  = 10.0
local ZE_SPEED_STEP = 0.2

-- ============================================
-- Zone Editor — Helper Functions
-- ============================================

-- Raycast ground position from camera
local function zeGetGroundPos()
    if not zeCam then return nil end
    local camPos = GetCamCoord(zeCam)
    local camRot = GetCamRot(zeCam, 2)
    local pitch  = math.rad(camRot.x)
    local yaw    = math.rad(camRot.z)
    local cosPitch = math.cos(pitch)
    local dirX = -math.sin(yaw) * cosPitch
    local dirY =  math.cos(yaw) * cosPitch
    local dirZ =  math.sin(pitch)
    local endPos = camPos + vector3(dirX, dirY, dirZ) * 200.0
    local _, hit, hitCoords = GetShapeTestResult(StartShapeTestRay(
        camPos.x, camPos.y, camPos.z, endPos.x, endPos.y, endPos.z, -1, PlayerPedId(), 0
    ))
    if hit == 1 then return hitCoords end
    -- Fallback: project 30m forward at camera height
    return camPos + vector3(dirX, dirY, 0) * 30.0
end

function EnterZoneEditor()
    if zeActive then return end   -- once — see EnterDoorEditor
    local ped = PlayerPedId()
    local playerCoords = GetEntityCoords(ped)
    local camRot = GetGameplayCamRot(2)

    PedHold.set('zoneEditor', { hidden = true, noCollision = true, invincible = true, frozen = true })
    SetLocalPlayerVisibleLocally(false)

    zeCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(zeCam, playerCoords.x, playerCoords.y, playerCoords.z + 5.0)
    SetCamRot(zeCam, camRot.x, 0.0, camRot.z, 2)
    SetCamFov(zeCam, 60.0)
    SetCamActive(zeCam, true)
    RenderScriptCams(true, false, 0, true, false)

    zeVelocity   = vector3(0, 0, 0)
    zeSpeed      = 1.0
    zeMode       = 'none'
    zeCreating   = false
    zeSelected   = nil
    zePolyPoints = {}
    zePolyClosed = false
    zeDraftSizeX = 10.0
    zeDraftSizeY = 10.0
    zeDraftSizeZ = 5.0
    zeDraftRadius = 10.0

    -- Force debug on all existing zones
    for _, z in ipairs(GetAllZones()) do
        Zones.setDebug(z.id, true)
    end

    -- Show the editor HUD. The /whip panel is already suspended (zmEnterEditor calls
    -- WhipPanelSuspend, which also released NUI focus).
    SendNUIMessage({ action = 'zeShow' })
    zeActive = true
    ZoneEditorActive = true
    -- The game's use of what the editor reads (fly, look, wheel, its keys), held off until ExitZoneEditor.
    ControlBlocks.hold('zoneEditor', { groups = { 'look', 'move' }, controls = { 37, 200, 24, 25, 241, 242,
        257, 47, 74, 75, 244, 38, 45, 157, 158, 160, 26, 177 } })
    startZeLoop()
end

function ExitZoneEditor()
    ControlBlocks.release('zoneEditor')   -- first: the collision wait below can take two seconds
    zeCapture = nil   -- a wizard's drawing ends with the editor, finished or not
    zeAdjust = nil
    zeActive = false
    ZoneEditorActive = false
    rsReset() -- clear any active room scan
    zeVertexMode = false; zeVertexIndex = nil; zeVertexOriginal = nil
    local ped = PlayerPedId()
    local finalCoords = zeCam and GetCamCoord(zeCam) or GetEntityCoords(ped)

    if zeCam then
        RenderScriptCams(false, false, 0, true, false)
        DestroyCam(zeCam, false)
        zeCam = nil
    end
    ClearFocus()

    RequestCollisionAtCoord(finalCoords.x, finalCoords.y, finalCoords.z)
    local timeout = 0
    while not HasCollisionLoadedAroundEntity(ped) and timeout < 2000 do
        Wait(10)
        timeout = timeout + 10
    end
    SetEntityCoordsNoOffset(ped, finalCoords.x, finalCoords.y, finalCoords.z, false, false, false)
    PedHold.release('zoneEditor')   -- its own hold only (client/ped_hold.lua)
    SetLocalPlayerVisibleLocally(true)

    SendNUIMessage({ action = 'zeHide' })

    -- Turn off debug on all zones
    for _, z in ipairs(GetAllZones()) do
        Zones.setDebug(z.id, false)
    end

    -- Hand the screen back to the /whip panel, with the section's data refreshed —
    -- the editor may have created/moved/deleted zones while the panel was suspended.
    WhipPanelResume()
    WhipPanelData('zones', 'all', { zones = GetAllZones() })
end

-- Format zone code for clipboard
local function zeFormatCode(zone)
    local code = ''
    if zone.type == 'box' then
        code = "local id = exports.whip_core:ZoneBox({\n"
        code = code .. ("    pos     = vec3(%.2f, %.2f, %.2f),\n"):format(zone.pos.x, zone.pos.y, zone.pos.z)
        code = code .. ("    size    = vec3(%.2f, %.2f, %.2f),\n"):format(zone.size.x, zone.size.y, zone.size.z)
        if zone.heading and zone.heading ~= 0 then
            code = code .. ("    heading = %.1f,\n"):format(zone.heading)
        end
    elseif zone.type == 'sphere' then
        code = "local id = exports.whip_core:ZoneSphere({\n"
        code = code .. ("    pos    = vec3(%.2f, %.2f, %.2f),\n"):format(zone.pos.x, zone.pos.y, zone.pos.z)
        code = code .. ("    radius = %.2f,\n"):format(zone.radius)
    elseif zone.type == 'poly' then
        code = "local id = exports.whip_core:ZonePoly({\n"
        code = code .. "    points = {\n"
        if zone.points then
            for _, p in ipairs(zone.points) do
                local px = p.x or p[1]
                local py = p.y or p[2]
                code = code .. ("        vec2(%.2f, %.2f),\n"):format(px, py)
            end
        end
        code = code .. "    },\n"
        if zone.minZ then code = code .. ("    minZ = %.2f,\n"):format(zone.minZ) end
        if zone.maxZ then code = code .. ("    maxZ = %.2f,\n"):format(zone.maxZ) end
    end
    -- %q: quoted for Lua, so a group with an apostrophe still pastes
    if zone.group then code = code .. ("    group = %q,\n"):format(tostring(zone.group)) end
    code = code .. "    onEnter = function(zone)\n"
    code = code .. "        -- entered\n"
    code = code .. "    end,\n"
    code = code .. "    onExit = function(zone)\n"
    code = code .. "        -- exited\n"
    code = code .. "    end,\n"
    code = code .. "})"
    return code
end

-- ============================================
-- Room Scanner — Helper Functions
-- ============================================

local function rsPerpDistance(px, py, lx1, ly1, lx2, ly2)
    local dx = lx2 - lx1
    local dy = ly2 - ly1
    local mag = math.sqrt(dx * dx + dy * dy)
    if mag < 0.001 then
        local ex = px - lx1
        local ey = py - ly1
        return math.sqrt(ex * ex + ey * ey)
    end
    local u = ((px - lx1) * dx + (py - ly1) * dy) / (mag * mag)
    local cx = lx1 + u * dx
    local cy = ly1 + u * dy
    return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
end

local function rsDouglasPeucker(points, epsilon)
    if #points <= 2 then return points end
    local maxDist = 0
    local maxIdx = 1
    local last = #points
    for i = 2, last - 1 do
        local d = rsPerpDistance(points[i].x, points[i].y, points[1].x, points[1].y, points[last].x, points[last].y)
        if d > maxDist then
            maxDist = d
            maxIdx = i
        end
    end
    if maxDist > epsilon then
        local left = {}
        for i = 1, maxIdx do left[#left + 1] = points[i] end
        local right = {}
        for i = maxIdx, last do right[#right + 1] = points[i] end
        left = rsDouglasPeucker(left, epsilon)
        right = rsDouglasPeucker(right, epsilon)
        local result = {}
        for i = 1, #left - 1 do result[#result + 1] = left[i] end
        for i = 1, #right do result[#result + 1] = right[i] end
        return result
    else
        return { points[1], points[last] }
    end
end

local function rsRebuildPolygon()
    if #rsAllHitPoints < 3 then rsSimplified = {}; return end

    -- Compute centroid
    local cx, cy = 0, 0
    for _, p in ipairs(rsAllHitPoints) do
        cx = cx + p.x
        cy = cy + p.y
    end
    cx = cx / #rsAllHitPoints
    cy = cy / #rsAllHitPoints

    -- Angular binning: 5 deg bins (72 bins), keep farthest per bin
    local bins = {}
    for _, p in ipairs(rsAllHitPoints) do
        local angle = math.atan(p.y - cy, p.x - cx)
        local deg = math.deg(angle)
        if deg < 0 then deg = deg + 360 end
        local binIdx = math.floor(deg / 5) + 1
        local dx = p.x - cx
        local dy = p.y - cy
        local dist = dx * dx + dy * dy
        if not bins[binIdx] or dist > bins[binIdx].dist then
            bins[binIdx] = { x = p.x, y = p.y, dist = dist }
        end
    end

    -- Collect binned points in order
    local ring = {}
    for i = 1, 72 do
        if bins[i] then ring[#ring + 1] = bins[i] end
    end
    if #ring < 3 then rsSimplified = ring; return end

    -- Neighbor-aware smoothing
    local dists = {}
    for i, p in ipairs(ring) do
        dists[i] = math.sqrt((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy))
    end
    local n = #ring
    for i = 1, n do
        local prev = dists[((i - 2) % n) + 1]
        local nextD = dists[(i % n) + 1]
        local neighborAvg = (prev + nextD) / 2
        if dists[i] > neighborAvg * 1.5 and neighborAvg > 0.5 then
            local dx = ring[i].x - cx
            local dy = ring[i].y - cy
            local len = dists[i]
            local clampTo = neighborAvg
            ring[i] = { x = cx + (dx / len) * clampTo, y = cy + (dy / len) * clampTo, dist = clampTo * clampTo }
            dists[i] = clampTo
        end
    end
    -- Second pass: catch remaining global outliers (median-based)
    local sorted = {}
    for _, d in ipairs(dists) do sorted[#sorted + 1] = d end
    table.sort(sorted)
    local median = sorted[math.floor(#sorted / 2)] or 10
    for i = 1, n do
        if dists[i] > median * 2.0 then
            local dx = ring[i].x - cx
            local dy = ring[i].y - cy
            local len = dists[i]
            local clampTo = median * 1.5
            ring[i] = { x = cx + (dx / len) * clampTo, y = cy + (dy / len) * clampTo, dist = clampTo * clampTo }
        end
    end

    -- Close the ring for Douglas-Peucker
    local closed = {}
    for _, p in ipairs(ring) do closed[#closed + 1] = { x = p.x, y = p.y } end
    closed[#closed + 1] = { x = ring[1].x, y = ring[1].y }

    -- Simplify
    local simplified = rsDouglasPeucker(closed, rsEpsilon)
    if #simplified > 1 then simplified[#simplified] = nil end

    rsSimplified = simplified
end

rsReset = function()
    rsScanActive = false
    rsScanning = false
    rsPreview = false
    rsAllHitPoints = {}
    rsSimplified = {}
    rsMinZ = nil
    rsMaxZ = nil
    rsLastBurstPos = nil
    rsBurstOrigin = nil
    rsBurstIndex = 0
    rsBurstActive = false
    rsFadeLines = {}
end

local function getSelectedZone()
    if not zeSelected then return nil end
    for _, z in ipairs(GetAllZones()) do
        if z.id == zeSelected then return z end
    end
    return nil
end

-- ============================================
-- Zone Editor — Input Thread
-- ============================================
--
-- Started by EnterZoneEditor, ended with the editor.

local zeLoopRunning = false

--- A shape finished in the editor: saved as a zone, or — drawing for the wizard (zeCapture) — handed
--- to the /whip Zones wizard as plain numbers (a vector does not survive the trip to the page), and the
--- editor closed, from its own thread as its Esc does.
local function zeCreate(data)
    if not zeCapture then
        TriggerServerEvent('whip_core:server:zeCreateZone', data)
        return
    end
    local function xyz(v) return v and { x = v.x + 0.0, y = v.y + 0.0, z = v.z + 0.0 } or nil end
    local shape = {
        type = data.type, pos = xyz(data.pos), size = xyz(data.size), heading = data.heading,
        radius = data.radius, minZ = data.minZ, maxZ = data.maxZ, points = nil,
    }
    if data.points then
        shape.points = {}
        for i, p in ipairs(data.points) do
            -- A corner's own floor and ceiling (vertex height mode, or kept by Move corners) go too.
            shape.points[i] = { x = p.x + 0.0, y = p.y + 0.0, minZ = p.minZ, maxZ = p.maxZ }
        end
    end
    zeCapture = nil
    zeAdjust = nil
    WhipPanelData('zones', 'shape', shape)
    CreateThread(ExitZoneEditor)
end

-- ============================================
-- Move corners: a polygon adjusted for the wizard
-- ============================================
--
-- Fixing a scanned shape by hand. The Zones wizard's Shape step opens the editor on a COPY of its polygon (zwAdjust, below; zeAdjust while it
-- runs). Aim at a corner and E picks it up, E again puts it down where you aim; F adds a corner where
-- you aim, on the side nearest it; R takes the aimed corner off; scroll raises or lowers the ceiling,
-- Ctrl+scroll the floor. G hands the polygon back to the wizard (zeCreate, above); Esc leaves it as
-- it was. Nothing is saved here — the wizard's Save changes does that, with everything else.
--
-- While it runs, zeCreating is on and zeMode is 'adjust', so the free editor's own keys (select,
-- delete, draw, scan) stay out of it: each of them asks for `not zeCreating` or for its own mode.

local ADJUST_REACH = 3.0   -- metres from where you aim that a corner is "the aimed one"
local ADJUST_STATUS = 'Corners: E picks up / puts down, F adds one, R takes one off. Scroll: ceiling, Ctrl+Scroll: floor. G: done, Esc: back'

--- The corner nearest where you aim, within ADJUST_REACH.
local function adjustAimedCorner(points, at)
    if not at then return nil end
    local best, bestD = nil, ADJUST_REACH
    for i, p in ipairs(points) do
        local d = math.sqrt((p.x - at.x) ^ 2 + (p.y - at.y) ^ 2)
        if d < bestD then best, bestD = i, d end
    end
    return best
end

--- The side (corner i to the next) nearest where you aim.
local function adjustNearestSide(points, at)
    local bestI, bestD = 1, math.huge
    for i = 1, #points do
        local a, b = points[i], points[(i % #points) + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local len2 = dx * dx + dy * dy
        local t = len2 > 0 and math.max(0.0, math.min(1.0, ((at.x - a.x) * dx + (at.y - a.y) * dy) / len2)) or 0.0
        local d = (at.x - (a.x + dx * t)) ^ 2 + (at.y - (a.y + dy * t)) ^ 2
        if d < bestD then bestI, bestD = i, d end
    end
    return bestI
end

local function adjustSay(text)
    SendNUIMessage({ action = 'zeStatus', text = text or ADJUST_STATUS })
end

--- One frame of Move corners: its keys, then the outline drawn.
local function zeAdjustFrame(groundPos)
    local a = zeAdjust
    ---@cast a -nil   (called only while it runs)
    local pts = a.points

    -- The corner being carried follows the aim.
    if a.carry and pts[a.carry] and groundPos then
        pts[a.carry].x = groundPos.x
        pts[a.carry].y = groundPos.y
    end
    local aimed = a.carry or adjustAimedCorner(pts, groundPos)

    -- E: pick the aimed corner up, or put the carried one down.
    if IsDisabledControlJustPressed(0, 38) then
        if a.carry then
            adjustSay('Corner ' .. a.carry .. ' put down. ' .. ADJUST_STATUS)
            a.carry, a.carryFrom = nil, nil
        elseif aimed then
            a.carry, a.carryFrom = aimed, { x = pts[aimed].x, y = pts[aimed].y }
            adjustSay('Carrying corner ' .. aimed .. ': aim where it goes, E puts it down, Esc puts it back')
        else
            adjustSay('Aim closer to a corner (the numbered posts)')
        end
    end

    -- F: a new corner where you aim, on the nearest side.
    if IsDisabledControlJustPressed(0, 75) and not a.carry and groundPos then
        local i = adjustNearestSide(pts, groundPos)
        table.insert(pts, i + 1, { x = groundPos.x, y = groundPos.y })
        adjustSay('Corner added (' .. #pts .. ' now). E picks it up to move it')
    end

    -- R: the aimed corner off (a shape keeps three).
    if IsDisabledControlJustPressed(0, 45) and not a.carry and aimed then
        if #pts <= 3 then
            adjustSay('A shape needs three corners at least')
        else
            table.remove(pts, aimed)
            adjustSay('Corner taken off (' .. #pts .. ' left)')
        end
    end

    -- Scroll: the ceiling; Ctrl+Scroll: the floor (Shift+Scroll is the camera's speed). A corner with
    -- its own height moves with it, so the shape keeps its slope.
    if not IsDisabledControlPressed(0, 21) then
        local step = (IsDisabledControlPressed(0, 241) and 0.25 or 0.0) - (IsDisabledControlPressed(0, 242) and 0.25 or 0.0)
        if step ~= 0.0 then
            local key = IsDisabledControlPressed(0, 36) and 'minZ' or 'maxZ'
            local nextZ = a[key] + step
            if (key == 'minZ' and nextZ < a.maxZ - 0.5) or (key == 'maxZ' and nextZ > a.minZ + 0.5) then
                a[key] = nextZ
                for _, p in ipairs(pts) do if p[key] then p[key] = p[key] + step end end
            end
        end
    end

    -- G: done, back to the wizard with it.
    if IsDisabledControlJustPressed(0, 47) and not a.carry then
        local cx, cy = 0.0, 0.0
        for _, p in ipairs(pts) do cx, cy = cx + p.x, cy + p.y end
        cx, cy = cx / #pts, cy / #pts
        zeCreating = false; zeMode = 'none'
        zeCreate({ type = 'poly', pos = vector3(cx, cy, (a.minZ + a.maxZ) / 2), points = pts, minZ = a.minZ, maxZ = a.maxZ })
        return
    end

    -- The outline: floor and ceiling, a post at each corner, numbered; the aimed one lit.
    local n = #pts
    for i = 1, n do
        local p, q = pts[i], pts[(i % n) + 1]
        local pLo, pHi = p.minZ or a.minZ, p.maxZ or a.maxZ
        local qLo, qHi = q.minZ or a.minZ, q.maxZ or a.maxZ
        DrawLine(p.x, p.y, pLo, q.x, q.y, qLo, 0, 220, 255, 200)
        DrawLine(p.x, p.y, pHi, q.x, q.y, qHi, 0, 220, 255, 200)
        local lit = i == aimed
        local r, g, b = 0, 220, 255
        if lit then r, g, b = (a.carry and 60 or 255), 255, (a.carry and 60 or 255) end
        DrawMarker(28, p.x, p.y, (pLo + pHi) / 2, 0, 0, 0, 0, 0, 0,
            lit and 0.45 or 0.3, lit and 0.45 or 0.3, pHi - pLo, r, g, b, lit and 170 or 70,
            false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
        SetDrawOrigin(p.x, p.y, pHi + 0.4, 0)
        SetTextScale(0.0, 0.3)
        SetTextFont(4)
        SetTextColour(255, 255, 255, lit and 255 or 190)
        SetTextOutline()
        SetTextCentre(true)
        SetTextEntry('STRING')
        AddTextComponentString(tostring(i))
        DrawText(0.0, 0.0)
        ClearDrawOrigin()
    end
end

local function zeLoop()
    local frameCount = 0
    while true do
        if zeActive and zeCam then
            -- ONE FRAME, CAUGHT. This loop holds the editor's only Esc exit: an uncaught error would
            -- leave the admin under the script camera, ped hidden, frozen and invincible. The error is
            -- printed and the editor is left properly.
            local frameOk, frameErr = pcall(function()
            local ped = PlayerPedId()
            local dt = GetFrameTime()

            -- Camera state
            local camCoords = GetCamCoord(zeCam)
            local camRot    = GetCamRot(zeCam, 2)

            -- Direction vectors
            local pitch    = math.rad(camRot.x)
            local yaw      = math.rad(camRot.z)
            local cosPitch = math.cos(pitch)
            local fwdX     = -math.sin(yaw) * cosPitch
            local fwdY     =  math.cos(yaw) * cosPitch
            local fwdZ     =  math.sin(pitch)
            local rightX   =  math.cos(yaw)
            local rightY   =  math.sin(yaw)

            -- Movement
            local moveSpeed = ZE_MOVE_SPEED * zeSpeed
            if IsDisabledControlPressed(0, 21) then moveSpeed = moveSpeed * ZE_FAST_MULT end

            if IsDisabledControlPressed(0, 32) then zeVelocity = zeVelocity + vector3(fwdX, fwdY, fwdZ) * moveSpeed * dt end
            if IsDisabledControlPressed(0, 33) then zeVelocity = zeVelocity - vector3(fwdX, fwdY, fwdZ) * moveSpeed * dt end
            if IsDisabledControlPressed(0, 35) then zeVelocity = zeVelocity + vector3(rightX, rightY, 0.0) * moveSpeed * dt end
            if IsDisabledControlPressed(0, 34) then zeVelocity = zeVelocity - vector3(rightX, rightY, 0.0) * moveSpeed * dt end
            if IsDisabledControlPressed(0, 22) then zeVelocity = zeVelocity + vector3(0, 0, moveSpeed) * dt end
            if IsDisabledControlPressed(0, 36) then zeVelocity = zeVelocity - vector3(0, 0, moveSpeed) * dt end

            zeVelocity = zeVelocity * (1.0 - ZE_DAMPING * dt)
            camCoords = camCoords + zeVelocity * dt

            -- Mouse rotation
            local mouseX   = GetDisabledControlNormal(0, 1) * ZE_SENSITIVITY
            local mouseY   = GetDisabledControlNormal(0, 2) * ZE_SENSITIVITY
            local newPitch = math.max(-89.0, math.min(89.0, camRot.x - mouseY))
            local newYaw   = camRot.z - mouseX
            camRot = vector3(newPitch, 0.0, newYaw)

            -- Speed adjust (Shift+Scroll)
            if IsDisabledControlPressed(0, 21) then
                if IsDisabledControlPressed(0, 241) then zeSpeed = math.min(ZE_SPEED_MAX, zeSpeed + ZE_SPEED_STEP) end
                if IsDisabledControlPressed(0, 242) then zeSpeed = math.max(ZE_SPEED_MIN, zeSpeed - ZE_SPEED_STEP) end
            end

            -- Apply camera
            SetCamCoord(zeCam, camCoords.x, camCoords.y, camCoords.z)
            SetCamRot(zeCam, camRot.x, camRot.y, camRot.z, 2)
            SetFocusPosAndVel(camCoords.x, camCoords.y, camCoords.z, 0.0, 0.0, 0.0)

            frameCount = frameCount + 1
            if frameCount >= 100 then
                frameCount = 0
                SetEntityCoordsNoOffset(ped, camCoords.x, camCoords.y, camCoords.z, false, false, false)
            end

            -- Ground position (raycast)
            local groundPos = zeGetGroundPos()

            -- Moving a polygon's corners for the wizard: its own keys and outline (zeAdjustFrame).
            if zeAdjust then zeAdjustFrame(groundPos) end

            -- ==========================================
            -- KEY HANDLING
            -- ==========================================

            -- 1: Box mode
            if IsDisabledControlJustPressed(0, 157) and not zeCreating and not rsScanActive and not zeVertexMode then
                zeMode = 'box'; zeCreating = true; zeDraftSizeX = 10; zeDraftSizeY = 10; zeDraftSizeZ = 5
                SendNUIMessage({ action = 'zeStatus', text = 'Box mode -- Scroll to resize, G to place' })
            end

            -- 2: Sphere mode
            if IsDisabledControlJustPressed(0, 158) and not zeCreating and not rsScanActive and not zeVertexMode then
                zeMode = 'sphere'; zeCreating = true; zeDraftRadius = 10
                SendNUIMessage({ action = 'zeStatus', text = 'Sphere mode -- Scroll to resize, G to place' })
            end

            -- 3: Poly mode
            if IsDisabledControlJustPressed(0, 160) and not zeCreating and not rsScanActive and not zeVertexMode then
                zeMode = 'poly'; zeCreating = true; zePolyPoints = {}; zePolyClosed = false; zeDraftMinZ = nil; zeDraftMaxZ = nil
                SendNUIMessage({ action = 'zeStatus', text = 'Poly mode -- G to add points, F to close, G to confirm' })
            end

            -- 4: Vertex POSITION mode / 5: Vertex HEIGHT mode
            local vertexKeyJustPressed = nil
            if zeVertexKeyPressed then vertexKeyJustPressed = 'position'; zeVertexKeyPressed = false end
            if zeHeightKeyPressed then vertexKeyJustPressed = 'height'; zeHeightKeyPressed = false end

            if vertexKeyJustPressed and zeSelected and not zeCreating and not rsScanActive then
                local vzone = getSelectedZone()
                if vzone and vzone.type == 'poly' and vzone.points and #vzone.points >= 3 then
                    if not zeVertexMode then
                        zeVertexMode = vertexKeyJustPressed
                        zeVertexIndex = nil
                        zeVertexOriginal = nil
                        if zeVertexMode == 'position' then
                            SendNUIMessage({ action = 'zeStatus', text = 'VERTEX POSITION -- E: grab, move camera, G: confirm, 4: exit' })
                        else
                            SendNUIMessage({ action = 'zeStatus', text = 'VERTEX HEIGHT -- E: select, Scroll: adjust Z, G: confirm, 5: exit' })
                        end
                    elseif zeVertexMode == vertexKeyJustPressed then
                        if zeVertexIndex then
                            if vzone and zeVertexOriginal then
                                vzone.points[zeVertexIndex] = zeVertexOriginal
                            end
                        end
                        zeVertexMode = false
                        zeVertexIndex = nil
                        zeVertexOriginal = nil
                        SendNUIMessage({ action = 'zeStatus', text = 'Exited vertex mode' })
                    else
                        if zeVertexIndex then
                            if vzone and zeVertexOriginal then
                                vzone.points[zeVertexIndex] = zeVertexOriginal
                            end
                            zeVertexIndex = nil
                            zeVertexOriginal = nil
                        end
                        zeVertexMode = vertexKeyJustPressed
                        if zeVertexMode == 'position' then
                            SendNUIMessage({ action = 'zeStatus', text = 'VERTEX POSITION -- E: grab, move camera, G: confirm, 4: exit' })
                        else
                            SendNUIMessage({ action = 'zeStatus', text = 'VERTEX HEIGHT -- E: select, Scroll: adjust Z, G: confirm, 5: exit' })
                        end
                    end
                elseif zeSelected then
                    SendNUIMessage({ action = 'zeStatus', text = 'Vertex edit only works on poly zones' })
                end
            end

            -- Scroll: resize draft
            if zeCreating and not IsDisabledControlPressed(0, 21) and not rsScanActive then
                if zeMode == 'box' then
                    if IsDisabledControlPressed(0, 36) then
                        if IsDisabledControlPressed(0, 241) then zeDraftSizeZ = math.min(100, zeDraftSizeZ + 0.5) end
                        if IsDisabledControlPressed(0, 242) then zeDraftSizeZ = math.max(1, zeDraftSizeZ - 0.5) end
                    elseif IsDisabledControlPressed(0, 38) then
                        if IsDisabledControlPressed(0, 241) then zeDraftSizeY = math.min(200, zeDraftSizeY + 0.5) end
                        if IsDisabledControlPressed(0, 242) then zeDraftSizeY = math.max(1, zeDraftSizeY - 0.5) end
                    else
                        if IsDisabledControlPressed(0, 241) then zeDraftSizeX = math.min(200, zeDraftSizeX + 0.5) end
                        if IsDisabledControlPressed(0, 242) then zeDraftSizeX = math.max(1, zeDraftSizeX - 0.5) end
                    end
                elseif zeMode == 'sphere' then
                    if IsDisabledControlPressed(0, 241) then zeDraftRadius = math.min(200, zeDraftRadius + 0.5) end
                    if IsDisabledControlPressed(0, 242) then zeDraftRadius = math.max(1, zeDraftRadius - 0.5) end
                elseif zeMode == 'poly' and zePolyClosed then
                    if IsDisabledControlPressed(0, 36) then
                        if IsDisabledControlPressed(0, 241) then zeDraftMinZ = (zeDraftMinZ or 28) + 0.5 end
                        if IsDisabledControlPressed(0, 242) then zeDraftMinZ = (zeDraftMinZ or 28) - 0.5 end
                    else
                        if IsDisabledControlPressed(0, 241) then zeDraftMaxZ = (zeDraftMaxZ or 35) + 0.5 end
                        if IsDisabledControlPressed(0, 242) then zeDraftMaxZ = (zeDraftMaxZ or 35) - 0.5 end
                    end
                end
            end

            -- G: Place / Confirm / Vertex confirm
            if IsDisabledControlJustPressed(0, 47) and not rsScanActive then
                if zeVertexMode and zeVertexIndex and zeSelected then
                    local vzone = getSelectedZone()
                    if vzone and vzone.type == 'poly' then
                        local pts = {}
                        for _, p in ipairs(vzone.points) do
                            local pt = { x = p.x or p[1], y = p.y or p[2] }
                            if p.maxZ then pt.maxZ = p.maxZ end
                            if p.minZ then pt.minZ = p.minZ end
                            pts[#pts + 1] = pt
                        end
                        TriggerServerEvent('whip_core:server:zeUpdateZone', zeSelected, {
                            points = pts,
                            minZ = vzone.minZ,
                            maxZ = vzone.maxZ,
                        })
                        SendNUIMessage({ action = 'zeStatus', text = 'Vertex ' .. zeVertexIndex .. ' placed -- E: grab another, 4: exit' })
                        zeVertexIndex = nil
                        zeVertexOriginal = nil
                    end
                elseif zeMode == 'box' and zeCreating and groundPos then
                    local heading = -newYaw
                    zeCreate({
                        type    = 'box',
                        label   = 'Box Zone',
                        pos     = groundPos,
                        size    = vector3(zeDraftSizeX, zeDraftSizeY, zeDraftSizeZ),
                        heading = heading,
                    })
                    zeCreating = false; zeMode = 'none'
                    SendNUIMessage({ action = 'zeStatus', text = 'Box zone created!' })

                elseif zeMode == 'sphere' and zeCreating and groundPos then
                    zeCreate({
                        type   = 'sphere',
                        label  = 'Sphere Zone',
                        pos    = groundPos,
                        radius = zeDraftRadius,
                    })
                    zeCreating = false; zeMode = 'none'
                    SendNUIMessage({ action = 'zeStatus', text = 'Sphere zone created!' })

                elseif zeMode == 'poly' and zeCreating then
                    if zePolyClosed then
                        local avgZ = 0
                        for _, p in ipairs(zePolyPoints) do avgZ = avgZ + (p.z or 0) end
                        avgZ = #zePolyPoints > 0 and avgZ / #zePolyPoints or 30
                        local pts = {}
                        for _, p in ipairs(zePolyPoints) do
                            pts[#pts + 1] = { x = p.x, y = p.y }
                        end
                        zeCreate({
                            type   = 'poly',
                            label  = 'Poly Zone',
                            pos    = vector3(pts[1].x, pts[1].y, avgZ),
                            points = pts,
                            minZ   = zeDraftMinZ or (avgZ - 3),
                            maxZ   = zeDraftMaxZ or (avgZ + 5),
                        })
                        zeCreating = false; zeMode = 'none'; zePolyPoints = {}; zePolyClosed = false
                        SendNUIMessage({ action = 'zeStatus', text = 'Poly zone created!' })
                    elseif groundPos then
                        zePolyPoints[#zePolyPoints + 1] = groundPos
                        SendNUIMessage({ action = 'zeStatus', text = #zePolyPoints .. ' points -- G add, F close' })
                    end
                end
            end

            -- F: Close polygon
            if IsDisabledControlJustPressed(0, 75) and not rsScanActive then
                if zeMode == 'poly' and zeCreating and #zePolyPoints >= 3 and not zePolyClosed then
                    zePolyClosed = true
                    local avgZ = 0
                    for _, p in ipairs(zePolyPoints) do avgZ = avgZ + p.z end
                    avgZ = avgZ / #zePolyPoints
                    zeDraftMinZ = avgZ - 3
                    zeDraftMaxZ = avgZ + 5
                    SendNUIMessage({ action = 'zeStatus', text = 'Polygon closed -- Scroll height, G to confirm' })
                end
            end

            -- E: Select nearest zone OR grab vertex in vertex mode
            if IsDisabledControlJustPressed(0, 38) and not zeCreating and not rsScanActive then
                if zeVertexMode and zeSelected and not zeVertexIndex then
                    local vzone = getSelectedZone()
                    if vzone and vzone.type == 'poly' and vzone.points and groundPos then
                        local bestIdx, bestDist2 = nil, 999
                        for i, pt in ipairs(vzone.points) do
                            local px = pt.x or pt[1]
                            local py = pt.y or pt[2]
                            local d = math.sqrt((px - groundPos.x)^2 + (py - groundPos.y)^2)
                            if d < bestDist2 and d < 10.0 then
                                bestDist2 = d; bestIdx = i
                            end
                        end
                        if bestIdx then
                            zeVertexIndex = bestIdx
                            local orig = vzone.points[bestIdx]
                            zeVertexOriginal = { x = orig.x or orig[1], y = orig.y or orig[2], maxZ = orig.maxZ, minZ = orig.minZ }
                            SendNUIMessage({ action = 'zeStatus', text = 'Vertex ' .. bestIdx .. ' grabbed -- move, Scroll: Z, G: confirm, Esc: cancel' })
                        else
                            SendNUIMessage({ action = 'zeStatus', text = 'No vertex nearby (aim closer)' })
                        end
                    end
                elseif not zeVertexMode and not zeCapture then
                    -- (Not while the wizard captures a shape: its keys are the wizard's.)
                    local allZones = GetAllZones()
                    local bestId, bestDist = nil, 999999
                    if groundPos then
                        for _, z in ipairs(allZones) do
                            if z.pos then
                                local d = #(vector3(z.pos.x, z.pos.y, z.pos.z) - groundPos)
                                if d < bestDist and d < 50.0 then
                                    bestDist = d; bestId = z.id
                                end
                            end
                        end
                    end
                    zeSelected = bestId
                    if bestId then
                        SendNUIMessage({ action = 'zeStatus', text = 'Selected: ' .. (bestId or '') })
                    else
                        SendNUIMessage({ action = 'zeStatus', text = 'No zone nearby' })
                    end
                end
            end

            -- R: Delete selected (the free editor's: never inside a wizard's capture)
            if IsDisabledControlJustPressed(0, 45) and zeSelected and not zeCreating and not rsScanActive and not zeCapture then
                local allZones = GetAllZones()
                local isDb = false
                for _, z in ipairs(allZones) do
                    if z.id == zeSelected and z.id:find('^dbzone_') then isDb = true; break end
                end
                if isDb then
                    TriggerServerEvent('whip_core:server:zeDeleteZone', zeSelected)
                else
                    Zones.remove(zeSelected)
                end
                SendNUIMessage({ action = 'zeStatus', text = 'Zone deleted' })
                zeSelected = nil
            end

            -- H: Copy code OR Room Scanner toggle
            if IsDisabledControlJustPressed(0, 74) then
                if zeSelected and not zeCreating and not rsScanActive and not zeCapture then
                    local allZones = GetAllZones()
                    for _, z in ipairs(allZones) do
                        if z.id == zeSelected then
                            CopyToClipboard(zeFormatCode(z))
                            break
                        end
                    end
                elseif not zeCreating and not zeSelected then
                    if not rsScanActive then
                        rsScanActive = true
                        rsScanning = true
                        rsPreview = false
                        rsAllHitPoints = {}
                        rsSimplified = {}
                        rsMinZ = nil
                        rsMaxZ = nil
                        rsLastBurstPos = nil
                        rsBurstOrigin = nil
                        rsBurstIndex = 0
                        rsBurstActive = false
                        rsFadeLines = {}
                        SendNUIMessage({ action = 'zeStatus', text = 'SCANNING -- Fly through the room, H to stop' })
                    elseif rsScanning then
                        rsScanning = false
                        rsBurstActive = false
                        if #rsSimplified >= 3 then
                            rsPreview = true
                            SendNUIMessage({ action = 'zeStatus', text = #rsSimplified .. ' pts -- Scroll: height, G: confirm, Backspace: clear, Esc: cancel' })
                        else
                            SendNUIMessage({ action = 'zeStatus', text = 'Not enough data -- need more wall hits. H to scan again' })
                            rsScanning = true
                        end
                    end
                end
            end

            -- C: Toggle labels (26, look behind)
            if IsDisabledControlJustPressed(0, 26) and not rsScanActive then
                zeLabelVis = not zeLabelVis
                SendNUIMessage({ action = 'zeStatus', text = 'Labels: ' .. (zeLabelVis and 'ON' or 'OFF') .. '  (C)' })
            end

            -- Esc: Exit
            if IsDisabledControlJustPressed(0, 200) then
                if zeVertexMode and zeVertexIndex then
                    local vzone = getSelectedZone()
                    if vzone and vzone.type == 'poly' and zeVertexOriginal then
                        vzone.points[zeVertexIndex] = zeVertexOriginal
                    end
                    zeVertexIndex = nil
                    zeVertexOriginal = nil
                    SendNUIMessage({ action = 'zeStatus', text = 'Vertex cancelled -- E: grab another, 4: exit' })
                elseif zeVertexMode then
                    zeVertexMode = false
                    zeVertexIndex = nil
                    zeVertexOriginal = nil
                    SendNUIMessage({ action = 'zeStatus', text = 'Exited vertex mode' })
                elseif zeAdjust and zeAdjust.carry then
                    -- Moving corners: a corner being carried goes back where it was first.
                    local p = zeAdjust.points[zeAdjust.carry]
                    if p and zeAdjust.carryFrom then p.x, p.y = zeAdjust.carryFrom.x, zeAdjust.carryFrom.y end
                    zeAdjust.carry, zeAdjust.carryFrom = nil, nil
                    SendNUIMessage({ action = 'zeStatus', text = 'Corner put back. Esc again: back to the wizard, nothing changed' })
                elseif zeCapture then
                    -- Drawing for the wizard: one Esc drops the shape half drawn and goes back to it
                    -- (the HUD and the page both say so). Nothing was saved, so nothing to ask.
                    zeCreating = false; zeMode = 'none'; zePolyPoints = {}; zePolyClosed = false
                    CreateThread(ExitZoneEditor)
                elseif rsScanActive then
                    rsReset()
                    SendNUIMessage({ action = 'zeStatus', text = 'Scan cancelled' })
                elseif zeCreating then
                    zeCreating = false; zeMode = 'none'; zePolyPoints = {}; zePolyClosed = false
                    SendNUIMessage({ action = 'zeStatus', text = 'Cancelled' })
                else
                    CreateThread(function()
                        local confirmed = UI.Confirm('Exit Zone Editor?', 'Created zones are saved to the database.')
                        if confirmed then
                            ExitZoneEditor()
                        end
                    end)
                end
            end

            -- ==========================================
            -- DRAFT ZONE RENDERING
            -- ==========================================

            if zeCreating and groundPos then
                if zeMode == 'box' then
                    local p = groundPos
                    local heading = -newYaw
                    local rad = math.rad(heading)
                    local cosH, sinH = math.cos(rad), math.sin(rad)
                    local hx, hy, hz = zeDraftSizeX / 2, zeDraftSizeY / 2, zeDraftSizeZ / 2
                    local corners = {}
                    for _, off in ipairs({{-hx,-hy},{hx,-hy},{hx,hy},{-hx,hy}}) do
                        corners[#corners+1] = {
                            x = off[1] * cosH - off[2] * sinH + p.x,
                            y = off[1] * sinH + off[2] * cosH + p.y,
                        }
                    end
                    for i = 1, 4 do
                        local j = (i % 4) + 1
                        DrawLine(corners[i].x, corners[i].y, p.z - hz, corners[j].x, corners[j].y, p.z - hz, 255, 200, 0, 200)
                        DrawLine(corners[i].x, corners[i].y, p.z + hz, corners[j].x, corners[j].y, p.z + hz, 255, 200, 0, 200)
                        DrawLine(corners[i].x, corners[i].y, p.z - hz, corners[i].x, corners[i].y, p.z + hz, 255, 200, 0, 200)
                    end
                elseif zeMode == 'sphere' then
                    DrawMarker(28, groundPos.x, groundPos.y, groundPos.z, 0, 0, 0, 0, 0, 0,
                        zeDraftRadius*2, zeDraftRadius*2, zeDraftRadius*2, 255, 200, 0, 40, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                elseif zeMode == 'poly' then
                    for i, p in ipairs(zePolyPoints) do
                        DrawMarker(28, p.x, p.y, p.z, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 0.5, 255, 200, 0, 200, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                        if i > 1 then
                            DrawLine(zePolyPoints[i-1].x, zePolyPoints[i-1].y, zePolyPoints[i-1].z,
                                     p.x, p.y, p.z, 255, 200, 0, 200)
                        end
                    end
                    if #zePolyPoints > 0 and groundPos and not zePolyClosed then
                        local last = zePolyPoints[#zePolyPoints]
                        DrawLine(last.x, last.y, last.z, groundPos.x, groundPos.y, groundPos.z, 255, 200, 0, 100)
                        DrawMarker(28, groundPos.x, groundPos.y, groundPos.z, 0, 0, 0, 0, 0, 0, 0.3, 0.3, 0.3, 255, 255, 0, 150, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                    end
                    if zePolyClosed and #zePolyPoints >= 3 then
                        local first = zePolyPoints[1]
                        local last = zePolyPoints[#zePolyPoints]
                        DrawLine(last.x, last.y, last.z, first.x, first.y, first.z, 255, 200, 0, 200)
                        local minZ = zeDraftMinZ or (first.z - 3)
                        local maxZ = zeDraftMaxZ or (first.z + 5)
                        for i2 = 1, #zePolyPoints do
                            local p2 = zePolyPoints[i2]
                            DrawLine(p2.x, p2.y, minZ, p2.x, p2.y, maxZ, 255, 200, 0, 120)
                        end
                    end
                end
            end

            -- ==========================================
            -- ROOM SCANNER -- State Machine + Rendering
            -- ==========================================
            if rsScanActive then
                local now = GetGameTimer()

                -- === SCANNING PHASE ===
                if rsScanning then
                    local camPos = GetCamCoord(zeCam)

                    local needBurst = false
                    if not rsLastBurstPos then
                        needBurst = true
                    else
                        local dx = camPos.x - rsLastBurstPos.x
                        local dy = camPos.y - rsLastBurstPos.y
                        local dz = camPos.z - rsLastBurstPos.z
                        if (dx*dx + dy*dy + dz*dz) > (RS_BURST_DIST * RS_BURST_DIST) then
                            needBurst = true
                        end
                    end

                    if needBurst and not rsBurstActive then
                        rsLastBurstPos = camPos
                        rsBurstOrigin = camPos
                        rsBurstIndex = 0
                        rsBurstActive = true
                    end

                    if rsBurstActive then
                        ---@cast rsBurstOrigin -nil   (set with rsBurstActive)
                        for _ = 1, RS_RAYS_PER_FRAME do
                            rsBurstIndex = rsBurstIndex + 1
                            if rsBurstIndex > rsRayCount then
                                rsBurstActive = false
                                rsRebuildPolygon()
                                local _, hitUp, hitUp3 = GetShapeTestResult(StartShapeTestRay(
                                    rsBurstOrigin.x, rsBurstOrigin.y, rsBurstOrigin.z,
                                    rsBurstOrigin.x, rsBurstOrigin.y, rsBurstOrigin.z + 20.0,
                                    1, ped, 0
                                ))
                                local _, hitDown, hitDown3 = GetShapeTestResult(StartShapeTestRay(
                                    rsBurstOrigin.x, rsBurstOrigin.y, rsBurstOrigin.z,
                                    rsBurstOrigin.x, rsBurstOrigin.y, rsBurstOrigin.z - 20.0,
                                    1, ped, 0
                                ))
                                local ceilZ = hitUp == 1 and hitUp3.z or (rsBurstOrigin.z + 5.0)
                                local floorZ = hitDown == 1 and hitDown3.z or (rsBurstOrigin.z - 5.0)
                                if not rsMaxZ or ceilZ > rsMaxZ then rsMaxZ = ceilZ end
                                if not rsMinZ or floorZ < rsMinZ then rsMinZ = floorZ end
                                SendNUIMessage({ action = 'zeStatus', text = 'SCANNING -- ' .. #rsAllHitPoints .. ' hits, ' .. #rsSimplified .. ' pts -- H to stop' })
                                break
                            end

                            local angle = (rsBurstIndex - 1) * (2 * math.pi / rsRayCount)
                            local dirX = math.cos(angle)
                            local dirY = math.sin(angle)
                            local endX = rsBurstOrigin.x + dirX * rsMaxRange
                            local endY = rsBurstOrigin.y + dirY * rsMaxRange
                            local endZ = rsBurstOrigin.z

                            local _, hit, hitCoords = GetShapeTestResult(StartShapeTestRay(
                                rsBurstOrigin.x, rsBurstOrigin.y, rsBurstOrigin.z,
                                endX, endY, endZ,
                                81, ped, 0
                            ))

                            local hitPt
                            if hit == 1 then
                                hitPt = hitCoords
                            else
                                hitPt = vector3(endX, endY, endZ)
                            end
                            rsAllHitPoints[#rsAllHitPoints + 1] = hitPt

                            rsFadeLines[#rsFadeLines + 1] = {
                                from = rsBurstOrigin,
                                to = hitPt,
                                time = now,
                            }
                        end
                    end
                end

                -- === PREVIEW PHASE ===
                if rsPreview then
                    if not IsDisabledControlPressed(0, 21) then
                        if IsDisabledControlPressed(0, 36) then
                            if IsDisabledControlPressed(0, 241) then rsMinZ = (rsMinZ or 25) + 0.5 end
                            if IsDisabledControlPressed(0, 242) then rsMinZ = (rsMinZ or 25) - 0.5 end
                        else
                            if IsDisabledControlPressed(0, 241) then rsMaxZ = (rsMaxZ or 30) + 0.5 end
                            if IsDisabledControlPressed(0, 242) then rsMaxZ = (rsMaxZ or 30) - 0.5 end
                        end
                    end

                    if IsDisabledControlJustPressed(0, 47) and #rsSimplified >= 3 then
                        local cx2, cy2 = 0, 0
                        for _, p in ipairs(rsSimplified) do
                            cx2 = cx2 + p.x
                            cy2 = cy2 + p.y
                        end
                        cx2 = cx2 / #rsSimplified
                        cy2 = cy2 / #rsSimplified
                        local avgZ = ((rsMinZ or 25) + (rsMaxZ or 30)) / 2
                        local pts = {}
                        for _, p in ipairs(rsSimplified) do
                            pts[#pts + 1] = { x = p.x, y = p.y }
                        end
                        zeCreate({
                            type   = 'poly',
                            label  = 'Scanned Zone',
                            pos    = vector3(cx2, cy2, avgZ),
                            points = pts,
                            minZ   = rsMinZ,
                            maxZ   = rsMaxZ,
                        })
                        rsReset()
                        SendNUIMessage({ action = 'zeStatus', text = 'Scanned zone created!' })
                    end

                    if IsDisabledControlJustPressed(0, 177) then
                        rsReset()
                        SendNUIMessage({ action = 'zeStatus', text = 'Scan data cleared' })
                    end
                end

                -- === VISUALIZATION ===
                local newFadeLines = {}
                for _, line in ipairs(rsFadeLines) do
                    local age = (now - line.time) / 1000.0
                    if age < RS_FADE_TIME then
                        local alpha = math.floor(200 * (1.0 - age / RS_FADE_TIME))
                        DrawLine(line.from.x, line.from.y, line.from.z,
                                 line.to.x, line.to.y, line.to.z,
                                 255, 200, 0, alpha)
                        newFadeLines[#newFadeLines + 1] = line
                    end
                end
                rsFadeLines = newFadeLines

                local startIdx = math.max(1, #rsAllHitPoints - 200)
                for i = startIdx, #rsAllHitPoints do
                    local p = rsAllHitPoints[i]
                    DrawMarker(28, p.x, p.y, p.z, 0,0,0, 0,0,0, 0.15,0.15,0.15, 0,255,0, 150,
                        false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                end

                if #rsSimplified >= 3 then
                    local minZ = rsMinZ or 25
                    local maxZ = rsMaxZ or 30
                    for i = 1, #rsSimplified do
                        local j = (i % #rsSimplified) + 1
                        local p = rsSimplified[i]
                        local np = rsSimplified[j]
                        DrawLine(p.x, p.y, minZ, np.x, np.y, minZ, 0, 220, 255, 200)
                        DrawLine(p.x, p.y, maxZ, np.x, np.y, maxZ, 0, 220, 255, 200)
                        DrawLine(p.x, p.y, minZ, p.x, p.y, maxZ, 0, 220, 255, 120)
                    end
                    for _, p in ipairs(rsSimplified) do
                        DrawMarker(28, p.x, p.y, (minZ + maxZ) / 2, 0,0,0, 0,0,0,
                            0.3, 0.3, maxZ - minZ, 0, 220, 255, 40,
                            false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                    end
                end

                if rsBurstOrigin then
                    local pulse = math.abs(math.sin(now / 300.0)) * 0.1 + 0.2
                    DrawMarker(28, rsBurstOrigin.x, rsBurstOrigin.y, rsBurstOrigin.z, 0,0,0, 0,0,0,
                        pulse, pulse, pulse, 255,255,255, 200,
                        false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                end
            end

            -- ==========================================
            -- VERTEX EDITOR -- Movement + Rendering
            -- ==========================================
            if zeVertexMode and zeSelected then
                local vzone = getSelectedZone()
                if vzone and vzone.type == 'poly' and vzone.points then
                    local globalMinZ = vzone.minZ or vzone.pos.z - 2
                    local globalMaxZ = vzone.maxZ or vzone.pos.z + 2

                    if zeVertexIndex and vzone.points[zeVertexIndex] then
                        local pt = vzone.points[zeVertexIndex]

                        if zeVertexMode == 'position' and groundPos then
                            pt.x = groundPos.x
                            pt.y = groundPos.y
                        end

                        if zeVertexMode == 'height' or zeVertexMode == 'position' then
                            if not IsDisabledControlPressed(0, 21) then
                                if IsDisabledControlPressed(0, 36) then
                                    pt.minZ = (pt.minZ or globalMinZ)
                                    if IsDisabledControlPressed(0, 241) then pt.minZ = pt.minZ + 0.5 end
                                    if IsDisabledControlPressed(0, 242) then pt.minZ = pt.minZ - 0.5 end
                                else
                                    pt.maxZ = (pt.maxZ or globalMaxZ)
                                    if IsDisabledControlPressed(0, 241) then pt.maxZ = pt.maxZ + 0.5 end
                                    if IsDisabledControlPressed(0, 242) then pt.maxZ = pt.maxZ - 0.5 end
                                end
                            end
                        end
                    end

                    for i, pt in ipairs(vzone.points) do
                        local px = pt.x or pt[1]
                        local py = pt.y or pt[2]
                        local vtxMaxZ = pt.maxZ or globalMaxZ
                        local vtxMinZ = pt.minZ or globalMinZ
                        local vtxMidZ = (vtxMinZ + vtxMaxZ) / 2
                        local vtxHeight = vtxMaxZ - vtxMinZ

                        if i == zeVertexIndex then
                            local pulse2 = math.abs(math.sin(GetGameTimer() / 200.0)) * 0.15 + 0.35
                            DrawMarker(28, px, py, vtxMidZ, 0,0,0, 0,0,0,
                                pulse2, pulse2, vtxHeight, 0, 255, 0, 180,
                                false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                        elseif zeVertexMode == 'height' then
                            DrawMarker(28, px, py, vtxMidZ, 0,0,0, 0,0,0,
                                0.3, 0.3, vtxHeight, 60, 160, 255, 120,
                                false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                        else
                            DrawMarker(28, px, py, vtxMidZ, 0,0,0, 0,0,0,
                                0.3, 0.3, vtxHeight, 255, 200, 0, 120,
                                false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                        end

                        SetDrawOrigin(px, py, vtxMaxZ + 0.5, 0)
                        SetTextScale(0.0, 0.25)
                        SetTextFont(4)
                        SetTextColour(255, 255, 255, 200)
                        SetTextOutline()
                        SetTextCentre(true)
                        SetTextEntry('STRING')
                        local label = tostring(i)
                        if pt.maxZ or pt.minZ then
                            label = label .. ' Z:' .. ('%.1f'):format(vtxMinZ) .. '-' .. ('%.1f'):format(vtxMaxZ)
                        end
                        AddTextComponentString(label)
                        DrawText(0.0, 0.0)
                        ClearDrawOrigin()
                    end
                end
            end

            -- Draw crosshair marker at ground pos
            if groundPos and zeCreating then
                DrawMarker(28, groundPos.x, groundPos.y, groundPos.z + 0.05, 0, 0, 0, 0, 0, 0,
                    0.15, 0.15, 0.15, 255, 255, 255, 200, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
            end

            -- Draw labels on existing zones
            if zeLabelVis then
                for _, z in ipairs(GetAllZones()) do
                    if z.pos then
                        local dist = #(vector3(z.pos.x, z.pos.y, z.pos.z) - camCoords)
                        if dist < 100.0 then
                            local label = z.label or z.id
                            if z.id == zeSelected then label = '> ' .. label .. ' <' end
                            SetDrawOrigin(z.pos.x, z.pos.y, z.pos.z + 1.0, 0)
                            SetTextScale(0.0, 0.28)
                            SetTextFont(4)
                            SetTextProportional(true)
                            SetTextColour(255, 255, 255, 200)
                            SetTextOutline()
                            SetTextCentre(true)
                            SetTextEntry('STRING')
                            AddTextComponentString(label)
                            DrawText(0.0, 0.0)
                            ClearDrawOrigin()
                        end
                    end
                end
            end

            -- NUI update (every 10 frames)
            if frameCount % 10 == 0 then
                SendNUIMessage({
                    action = 'zeUpdate',
                    mode   = zeMode,
                    creating = zeCreating,
                    selected = zeSelected,
                    pos    = groundPos and { x = math.floor(groundPos.x * 100) / 100, y = math.floor(groundPos.y * 100) / 100, z = math.floor(groundPos.z * 100) / 100 } or nil,
                    sizeX  = zeDraftSizeX,
                    sizeY  = zeDraftSizeY,
                    sizeZ  = zeDraftSizeZ,
                    radius = zeDraftRadius,
                    polyPts = zeAdjust and #zeAdjust.points or #zePolyPoints,
                    polyClosed = zePolyClosed,
                    speed  = math.floor(zeSpeed * 10) / 10,
                    zoneCount = #GetAllZones(),
                    scanActive = rsScanActive,
                    scanScanning = rsScanning,
                    scanPreview = rsPreview,
                    scanHits = #rsAllHitPoints,
                    scanPoints = #rsSimplified,
                    scanMinZ = rsMinZ and math.floor(rsMinZ * 10) / 10 or nil,
                    scanMaxZ = rsMaxZ and math.floor(rsMaxZ * 10) / 10 or nil,
                })
            end
            end)
            if not frameOk then
                print('[whip_core:zones] the zone editor errored and was closed: ' .. tostring(frameErr))
                pcall(ExitZoneEditor)
            end

            Wait(0)
        else
            break
        end
    end
    zeLoopRunning = false
end

startZeLoop = function()
    if zeLoopRunning then return end
    zeLoopRunning = true
    CreateThread(zeLoop)
end

-- Key 4: Vertex edit mode toggle
RegisterCommand('ze_vertex_mode', function()
    if zeActive and zeCam then
        zeVertexKeyPressed = true
    end
end, false)
RegisterKeyMapping('ze_vertex_mode', 'Zone Editor: Vertex Mode', 'keyboard', '4')

-- Key 5: Vertex height mode toggle
RegisterCommand('ze_height_mode', function()
    if zeActive and zeCam then
        zeHeightKeyPressed = true
    end
end, false)
RegisterKeyMapping('ze_height_mode', 'Zone Editor: Vertex Height Mode', 'keyboard', '5')

-- NUI callback: Enter editor from the /whip Zones section. The panel SUSPENDS (hidden,
-- focus released, section state intact) while the in-world editor owns the screen;
-- the editor's exit path resumes it.
RegisterNUICallback('zmEnterEditor', function(_, cb)
    WhipPanelSuspend()
    EnterZoneEditor()
    cb('ok')
end)

-- ============================================
-- The Zones wizard (html/js/wp/zones.js)
-- ============================================
--
-- zwDraw opens the editor to draw one shape for the wizard, straight into it (what 1, 2, 3 or H does
-- in the editor); the finished shape comes back as 'shape' (zeCreate, above). zwCreate and zwUpdate
-- save the zone whole — the same server events the editor and the old page used.

local DRAW_STATUS = {
    box    = 'Drawing a box: Scroll one side, E+Scroll the other, Ctrl+Scroll its height; G puts it down. Esc: back',
    sphere = 'Drawing a sphere: Scroll its size; G puts it down. Esc: back',
    poly   = 'Drawing a polygon: G a corner at a time, F to close it, Scroll its top (Ctrl: its bottom), G again to finish. Esc: back',
    scan   = 'Scanning a room: H starts it, walk the room, then G to finish. Esc: back',
}

RegisterNUICallback('zwDraw', function(data, cb)
    data = type(data) == 'table' and data or {}
    local shape = data.shape
    if not DRAW_STATUS[shape] then cb({ ok = false, why = 'Pick a shape first' }) return end
    if zeActive then cb({ ok = false, why = 'The zone editor is already open' }) return end
    if PropertyEditorActive then cb({ ok = false, why = 'Something else is using the world editor' }) return end

    zeCapture = { shape = shape }
    WhipPanelSuspend()
    EnterZoneEditor()
    if shape == 'box' then
        local s = type(data.size) == 'table' and data.size or {}
        zeMode = 'box'; zeCreating = true
        zeDraftSizeX = tonumber(s.x) or 10.0; zeDraftSizeY = tonumber(s.y) or 10.0; zeDraftSizeZ = tonumber(s.z) or 5.0
    elseif shape == 'sphere' then
        zeMode = 'sphere'; zeCreating = true; zeDraftRadius = tonumber(data.radius) or 10.0
    elseif shape == 'poly' then
        zeMode = 'poly'; zeCreating = true; zePolyPoints = {}; zePolyClosed = false; zeDraftMinZ = nil; zeDraftMaxZ = nil
    end
    SendNUIMessage({ action = 'zeStatus', text = DRAW_STATUS[shape] })
    cb({ ok = true })
end)

--- Move corners (above): the editor opened on a copy of the wizard's polygon, the camera over it.
RegisterNUICallback('zwAdjust', function(data, cb)
    local g = type(data) == 'table' and type(data.geo) == 'table' and data.geo or {}
    if g.type ~= 'poly' or type(g.points) ~= 'table' then cb({ ok = false, why = 'Only a polygon has corners to move' }) return end
    if zeActive then cb({ ok = false, why = 'The zone editor is already open' }) return end
    if PropertyEditorActive then cb({ ok = false, why = 'Something else is using the world editor' }) return end

    local pts, cx, cy = {}, 0.0, 0.0
    for _, p in ipairs(g.points) do
        local x, y = tonumber(type(p) == 'table' and p.x), tonumber(type(p) == 'table' and p.y)
        if x and y then
            pts[#pts + 1] = { x = x + 0.0, y = y + 0.0, minZ = tonumber(p.minZ), maxZ = tonumber(p.maxZ) }
            cx, cy = cx + x, cy + y
        end
    end
    if #pts < 3 then cb({ ok = false, why = 'This polygon has fewer than three corners' }) return end
    cx, cy = cx / #pts, cy / #pts
    local standZ = type(g.pos) == 'table' and tonumber(g.pos.z) or GetEntityCoords(PlayerPedId()).z
    local minZ = tonumber(g.minZ) or (standZ - 3.0)
    local maxZ = tonumber(g.maxZ) or (standZ + 5.0)
    if maxZ <= minZ + 0.5 then maxZ = minZ + 3.0 end

    zeAdjust = { points = pts, minZ = minZ, maxZ = maxZ }
    zeCapture = { shape = 'adjust' }
    WhipPanelSuspend()
    EnterZoneEditor()
    ---@cast zeCam integer   (EnterZoneEditor made it: the editor was shut)
    zeMode = 'adjust'; zeCreating = true
    -- Above the outline, looking down on it, whoever opened it from wherever.
    local camZ = maxZ + 10.0
    SetCamCoord(zeCam, cx, cy - 8.0, camZ)
    SetCamRot(zeCam, -55.0, 0.0, 0.0, 2)
    SetFocusPosAndVel(cx, cy, camZ, 0.0, 0.0, 0.0)
    SendNUIMessage({ action = 'zeStatus', text = ADJUST_STATUS })
    cb({ ok = true })
end)

--- The page's numbers as the game's: a vector where the zone code does vector maths on it.
local function asVector(t)
    if type(t) ~= 'table' then return nil end
    return vector3(tonumber(t.x) or 0.0, tonumber(t.y) or 0.0, tonumber(t.z) or 0.0)
end

local function refreshSoon()
    Wait(500)   -- the server's broadcast of the change lands first
    SendNUIMessage({ action = 'zmRefresh', zones = GetAllZones() })
end

RegisterNUICallback('zwCreate', function(data, cb)
    if type(data) ~= 'table' or not data.type or type(data.pos) ~= 'table' then
        cb({ ok = false, why = 'The zone has no shape yet' })
        return
    end
    data.pos = asVector(data.pos)
    if data.size then data.size = asVector(data.size) end
    TriggerServerEvent('whip_core:server:zeCreateZone', data)
    cb({ ok = true })
    refreshSoon()
end)

--- To the shape being drawn (the wizard's own, which may not be saved yet).
RegisterNUICallback('zwTeleport', function(data, cb)
    local x, y, z = tonumber(data and data.x), tonumber(data and data.y), tonumber(data and data.z)
    if x and y and z then SetEntityCoords(PlayerPedId(), x, y, z, false, false, false, false) end
    cb('ok')
end)

RegisterNUICallback('zwUpdate', function(data, cb)
    if type(data) ~= 'table' or type(data.id) ~= 'string' or type(data.updates) ~= 'table' then
        cb({ ok = false, why = 'Nothing to save' })
        return
    end
    local u = data.updates
    if u.pos then u.pos = asVector(u.pos) end
    if u.size then u.size = asVector(u.size) end
    TriggerServerEvent('whip_core:server:zeUpdateZone', data.id, u)
    cb({ ok = true })
    refreshSoon()
end)

-- ============================================
-- Door Editor — State
-- ============================================

local deActive     = false
local deCam        = nil
local startDeLoop  -- the editor's input loop, started by EnterDoorEditor; defined with it below
local deVelocity   = vector3(0, 0, 0)
local deSpeed      = 1.0
local deLink1      = nil      -- the first of two doors being linked (its doorId)
local deLink1Body  = nil      -- where it is (DoorLeaf.body), for the line to the second
local deLink2      = nil

-- ---- WHAT IS DRAWN (the same as the property editor's Edit Doors: the door itself lights up) ----
--
-- Every saved door near the camera is lit on its leaf, with the property picker's drawing (tools/door_leaf.lua):
-- green, or grey when a system manages it (a property's door, changed there), and a white line between linked
-- leaves. The one aimed at is brighter, outlined white and named over its top; an object that is not a door yet
-- lights amber. The ray stops at walls now (it took objects only, so a door behind a wall was the one aimed at),
-- and a saved door near the line of sight is taken when the ray finds no object (a door standing open, edge on).
local deDoors      = {}    -- every saved door, whole (GetAllDoorsForTool): read at entry, after a change, and every DE_READ_MS
local deById       = {}    -- doorId -> its record
local deNear       = {}    -- those within DE_NEAR of the camera, picked four times a second
local deNearAt     = 0
local deSlots      = {}    -- doorId -> { entity, lookAt }: its object (DoorLeaf.entity)
---@type { set: fun(ent: integer|nil) }|nil
local deOutline    = nil   -- DoorLeaf.outliner(), while the editor is open
local deReading    = false
local deReadAt     = 0

-- ---- PICKING FOR THE WIZARD (html/js/wp/doors.js) ----
--
-- The wizard opens this editor to pick ONE door: one leaf, or both leaves of a double door. { leaves = { { model,
-- x, y, z, heading } }, done } while it does. G (A) takes the door aimed at or lets a taken one go, Enter (☰) goes
-- back with them, Esc (B) goes back without. Nothing is saved here: the wizard's Create saves the door whole.
---@type { leaves: table[], done: boolean }|nil
local deCapture    = nil

local DE_NEAR    = 60.0
local DE_READ_MS = 5000
local DE_RGB = {
    saved   = { 74, 222, 128 },    -- a whip door
    managed = { 148, 163, 184 },   -- a whip door a system manages (a property's)
    new     = { 251, 191, 36 },    -- aimed at, not a door yet
    link    = { 192, 132, 252 },   -- the first of two being linked
    picked  = { 96, 165, 250 },    -- taken for the wizard
}

local function deManaged(d)
    local mb = d and d.metadata and d.metadata.managedBy
    return type(mb) == 'table'
end

local function deSlot(doorId)
    local s = deSlots[doorId]
    if not s then s = {} deSlots[doorId] = s end
    return s
end

local function deBody(d, heading)
    if not d._body then d._body = DoorLeaf.body(d.model, d.x, d.y, d.z, d.heading or heading or 0.0) end
    return d._body
end

--- The list, read in a thread of its own: a server round trip, which the editor's frames must not wait for. A
--- change asks again sooner (deReadAt = now + a moment), which a read already out does not undo.
local function deRead()
    if deReading then return end
    deReading = true
    local asked = deReadAt
    CreateThread(function()
        local list = GetAllDoorsForTool()
        deReading = false
        if not deActive then return end
        deDoors = list or {}
        deById = {}
        for _, d in ipairs(deDoors) do deById[d.doorId] = d end
        deNearAt = 0
        if deReadAt == asked then deReadAt = GetGameTimer() + DE_READ_MS end
    end)
end

local function deNearby(cam)
    local near = {}
    for _, d in ipairs(deDoors) do
        local dx, dy, dz = d.x - cam.x, d.y - cam.y, d.z - cam.z
        if dx * dx + dy * dy + dz * dz < DE_NEAR * DE_NEAR then
            deBody(d)
            near[#near + 1] = d
        end
    end
    deNear = near
end

--- A saved door near the line of sight: nearest to the view ray, within 30 m and 0.9 m of it (the picker's).
local function deNearestToSight(cam, fx, fy, fz)
    local best, bestD = nil, 0.9
    for _, d in ipairs(deNear) do
        local p = d._body
        local vx, vy, vz = p.x - cam.x, p.y - cam.y, p.z - cam.z
        local t = vx * fx + vy * fy + vz * fz
        if t > 0 and t < 30.0 then
            local px, py, pz = vx - fx * t, vy - fy * t, vz - fz * t
            local dist = math.sqrt(px * px + py * py + pz * pz)
            if dist < bestD then best, bestD = d, dist end
        end
    end
    return best
end

--- The wizard's leaf this object is, or nil.
local function deLeafOf(ent)
    if not (deCapture and ent) then return nil end
    local m = PropertyMath.signedHash(GetEntityModel(ent))
    local p = GetEntityCoords(ent)
    for i, l in ipairs(deCapture.leaves) do
        if l.entity == ent then return i end
        local dx, dy, dz = l.x - p.x, l.y - p.y, l.z - p.z
        if PropertyMath.signedHash(l.model) == m and dx * dx + dy * dy + dz * dz < 0.25 then
            l.entity = ent
            return i
        end
    end
    return nil
end

local function deLabel(x, y, z, text)
    SetDrawOrigin(x + 0.0, y + 0.0, z + 0.0, 0)
    SetTextScale(0.0, 0.3)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 235)
    SetTextOutline()
    SetTextCentre(true)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(0.0, 0.0)
    ClearDrawOrigin()
end

-- ---- THE CARD ----
--
-- The editor's card is the shared EditorHud's house look (tools/editor_hud.lua, html/js/editor-hud.js): the
-- door glyph, what is happening and the target's state, the readings, and every control with its key on a
-- keyboard and its button on a pad (the page shows whichever the player is on). Its old box of its own
-- (#door-editor-hud, html/js/door-editor.js) is no longer shown.

local DE_FLY_HINTS = {
    { key = 'WASD',           pad = 'ls',                       text = 'Move',      group = 'fly' },
    { key = 'Mouse',          pad = 'rs',                       text = 'Look',      group = 'fly' },
    { key = 'Space / Ctrl',   pad = { 'rt', 'lt' },             text = 'Up / down', group = 'fly' },
    { key = 'Shift',          pad = 'rb',                       text = 'Faster',    group = 'fly' },
    { key = 'Shift + Scroll', pad = { 'dpad_up', 'dpad_down' }, text = 'Speed',     group = 'fly' },
}

local function deWhere(x, y, z)
    return ('%.1f, %.1f, %.1f'):format(x, y, z)
end

--- Picking for the wizard: what is taken, and the three keys.
local function deCaptureCard(aimDoor, aimEnt)
    ---@cast deCapture -nil   (only asked for while picking: deCard)
    local leaves = deCapture.leaves
    local n = #leaves
    local leafAt = deLeafOf(aimEnt)
    local sub
    if aimDoor then sub = ('Door #%d is a door already'):format(aimDoor.doorId)
    elseif leafAt then sub = ('Leaf %d of the door'):format(leafAt)
    elseif aimEnt then sub = n == 0 and 'Aiming at a door' or 'Aiming at another door'
    else sub = 'Aim at the door' end
    local function leafRow(i)
        local l = leaves[i]
        return l and deWhere(l.x, l.y, l.z) or (i == 2 and n == 1 and 'none: a single door' or nil)
    end
    local takeText = leafAt and 'Let this leaf go' or n == 0 and 'Take this door' or 'Take its other leaf'
    local hints = {
        { key = 'G',     pad = 'a',    text = takeText, off = not aimEnt or aimDoor ~= nil or (n >= 2 and not leafAt) },
        { key = 'Enter', pad = 'menu', text = 'Done', off = n == 0 },
        { key = 'Esc',   pad = 'b',    text = 'Back, taking nothing' },
    }
    for _, h in ipairs(DE_FLY_HINTS) do hints[#hints + 1] = h end
    return {
        house = true, icon = 'door', title = 'Pick the door', sub = sub,
        chip = { text = n == 0 and 'Nothing taken' or n == 1 and 'One leaf' or 'Double door', tone = n > 0 and 'ok' or nil },
        rows = {
            { label = 'Leaf 1',       value = leafRow(1) },
            { label = 'Leaf 2',       value = leafRow(2) },
            { label = 'Camera speed', value = ('×%.1f'):format(deSpeed) },
        },
        hints = hints,
    }
end

--- The card's state from the editor's: the saved door the camera is on (its record), or the object (not a door
--- yet), or neither.
local function deCard(aimDoor, aimEnt)
    if deCapture then return deCaptureCard(aimDoor, aimEnt) end
    local sub, chip
    if deLink1 then
        sub = ('Linking door #%d: aim at the second'):format(deLink1)
    elseif aimDoor then
        sub = ('Aiming at door #%d'):format(aimDoor.doorId)
    elseif aimEnt then
        sub = 'Aiming at something that is not a door yet'
    else
        sub = 'Aim at a door'
    end
    if aimDoor then
        chip = deManaged(aimDoor) and { text = 'Managed #' .. aimDoor.doorId, tone = 'warn' }
            or { text = 'Saved #' .. aimDoor.doorId, tone = 'ok' }
    elseif aimEnt then chip = { text = 'Not saved', tone = 'warn' }
    else chip = { text = 'No door' } end
    local model, pos
    if aimDoor then
        model, pos = aimDoor.model, deWhere(aimDoor.x, aimDoor.y, aimDoor.z)
    elseif aimEnt then
        local p = GetEntityCoords(aimEnt)
        model, pos = GetEntityModel(aimEnt), deWhere(p.x, p.y, p.z)
    end
    local linked = aimDoor and aimDoor.linkedDoorId
    local hints = {
        { key = 'G',   pad = 'a', text = 'Save door',   off = not (aimEnt and not aimDoor) },
        { key = 'E',   pad = 'x', text = deLink1 and 'Link to this door' or 'Link two doors', off = not aimDoor },
        { key = 'R',   pad = 'y', text = 'Delete door', off = not aimDoor },
        { key = 'Esc', pad = 'b', text = deLink1 and 'Cancel link' or 'Exit' },
    }
    for _, h in ipairs(DE_FLY_HINTS) do hints[#hints + 1] = h end
    return {
        house = true, icon = 'door', title = 'Door Editor', sub = sub, chip = chip,
        rows = {
            { label = 'Name',         value = aimDoor and (aimDoor.label or 'Door') or nil },
            { label = 'Model',        value = model and tostring(model) or nil },
            { label = 'Position',     value = pos },
            { label = 'Linked to',    value = aimDoor and (linked and ('#' .. linked) or 'nothing') or nil },
            { label = 'Doors saved',  value = tostring(TotalDoorCount or 0) },
            { label = 'Camera speed', value = ('×%.1f'):format(deSpeed) },
        },
        hints = hints,
    }
end

--- A line on the card for three seconds: 'ok' (green, the default), 'warn', 'err' or 'info'.
local function deSay(text, kind)
    EditorHud.status(text, kind)
end

--- `capture`: picking for the wizard ({ leaves }, the ones it has already), not editing.
function EnterDoorEditor(capture)
    -- ONCE: a second entry would make a second camera over the first and lose the way back.
    if deActive then return end
    local ped = PlayerPedId()
    local playerCoords = GetEntityCoords(ped)
    local camRot = GetGameplayCamRot(2)

    PedHold.set('doorEditor', { hidden = true, noCollision = true, invincible = true, frozen = true })
    SetLocalPlayerVisibleLocally(false)

    deCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(deCam, playerCoords.x, playerCoords.y, playerCoords.z + 2.0)
    SetCamRot(deCam, camRot.x, 0.0, camRot.z, 2)
    SetCamFov(deCam, 60.0)
    SetCamActive(deCam, true)
    RenderScriptCams(true, false, 0, true, false)

    deVelocity = vector3(0, 0, 0)
    deSpeed = 1.0
    deLink1 = nil
    deLink1Body = nil
    deLink2 = nil
    deCapture = nil
    if type(capture) == 'table' then
        deCapture = { leaves = {}, done = false }
        for _, l in ipairs(capture.leaves or {}) do
            deCapture.leaves[#deCapture.leaves + 1] = { model = l.model, x = l.x, y = l.y, z = l.z, heading = l.heading }
        end
    end

    DoorManagerOpen = false
    -- The /whip panel is already suspended (dmEnterEditor called WhipPanelSuspend,
    -- which also released NUI focus); just show the editor's card.
    -- The list: TotalDoorCount for the card (client/doors.lua, its owner) and every door to light up.
    deDoors = GetAllDoorsForTool()
    deById, deSlots, deNear, deNearAt = {}, {}, {}, 0
    for _, d in ipairs(deDoors) do deById[d.doorId] = d end
    deReadAt = GetGameTimer() + DE_READ_MS
    deOutline = DoorLeaf.outliner()
    EditorHud.show(deCard(nil, nil))
    deActive = true
    DoorEditorActive = true   -- read by IsAnyUIOpen and IsInteractionBlocked
    -- What the editor reads, off the game until ExitDoorEditor (as the zone editor's). On a pad too: the
    -- character wheel and phone (19, 20, 27), get in (23), cover (44: RB, Faster), the cinematic camera (80),
    -- the radio wheel (85) and the melee buttons, which the pad's A / B / X / Y and D-pad would otherwise press.
    -- Picking for the wizard reads Done too: Enter (18, 201) and the pad's ☰ (199, the pause menu, which the
    -- block naming it makes stand aside — the furnisher's way).
    local controls = { 37, 200, 24, 25, 241, 242, 257, 47, 38, 45, 26, 19, 20, 23, 27, 44, 80, 85, 140, 141, 142, 143 }
    if deCapture then
        for _, c in ipairs({ 18, 201, 199 }) do controls[#controls + 1] = c end
    end
    ControlBlocks.hold('doorEditor', { groups = { 'look', 'move' }, controls = controls })
    startDeLoop()
end

function ExitDoorEditor()
    -- Not safe twice (tools/core.lua asks DoorEditorActive first): the wizard's Done and Back can land in one frame.
    if not deActive then return end
    ControlBlocks.release('doorEditor')   -- first: the collision wait below can take two seconds
    deActive = false
    DoorEditorActive = false
    local ped = PlayerPedId()
    local finalCoords = deCam and GetCamCoord(deCam) or GetEntityCoords(ped)

    if deCam then
        RenderScriptCams(false, false, 0, true, false)
        DestroyCam(deCam, false)
        deCam = nil
    end
    ClearFocus()

    RequestCollisionAtCoord(finalCoords.x, finalCoords.y, finalCoords.z)
    local timeout = 0
    while not HasCollisionLoadedAroundEntity(ped) and timeout < 2000 do
        Wait(10); timeout = timeout + 10
    end
    SetEntityCoordsNoOffset(ped, finalCoords.x, finalCoords.y, finalCoords.z, false, false, false)
    PedHold.release('doorEditor')   -- its own hold only (client/ped_hold.lua)
    SetLocalPlayerVisibleLocally(true)

    if deOutline then deOutline.set(nil) deOutline = nil end
    deDoors, deById, deNear, deSlots = {}, {}, {}, {}
    local capture = deCapture
    deCapture = nil

    EditorHud.hide()
    -- Hand the screen back to the /whip panel with fresh door data, and its live refresh back on
    -- (entering cleared DoorManagerOpen), so changes by other admins keep reaching the list.
    WhipPanelResume()
    DoorManagerOpen = true
    WhipPanelData('doors', 'all', { doors = GetAllDoorsForTool() })
    -- The wizard's pick: the leaves taken (Done), or none (Back: the wizard keeps what it had).
    if capture then
        local leaves = nil
        if capture.done then
            leaves = {}
            for _, l in ipairs(capture.leaves) do
                leaves[#leaves + 1] = { model = l.model, x = l.x, y = l.y, z = l.z, heading = l.heading }
            end
        end
        WhipPanelData('doors', 'wizPick', { leaves = leaves })
    end
end

-- Door Editor Input Thread — started by EnterDoorEditor, ended with the editor, as the zone
-- editor's above.
local deLoopRunning = false

local function deLoop()
    local frameCount = 0
    local DE_MOVE_SPEED = 30.0
    local DE_FAST_MULT = 3.0
    local DE_SENSITIVITY = 5.0
    local DE_DAMPING = 8.0
    -- A pad: the frontend buttons the panel driver reads too (client/pad.lua's SLOTS).
    local DE_PAD_A, DE_PAD_B, DE_PAD_X, DE_PAD_Y, DE_PAD_RB = 201, 202, 203, 204, 206
    local DE_PAD_UP, DE_PAD_DOWN = 188, 187
    local DE_PAD_DEAD = 0.15      -- a stick at rest reads a little off the middle
    local DE_PAD_LOOK = 130.0     -- degrees a second, the right stick fully over

    while true do
        if deActive and deCam then
            -- ONE FRAME, CAUGHT — as the zone editor's above: this loop holds the only Esc exit.
            local frameOk, frameErr = pcall(function()
            local ped = PlayerPedId()
            local dt = GetFrameTime()

            -- Camera movement
            local camCoords = GetCamCoord(deCam)
            local camRot    = GetCamRot(deCam, 2)
            local pitch     = math.rad(camRot.x)
            local yaw       = math.rad(camRot.z)
            local cosPitch  = math.cos(pitch)
            local fwdX      = -math.sin(yaw) * cosPitch
            local fwdY      =  math.cos(yaw) * cosPitch
            local fwdZ      =  math.sin(pitch)
            local rightX    =  math.cos(yaw)
            local rightY    =  math.sin(yaw)

            -- ONE DEVICE AT A TIME: a pad's buttons are the same controls as
            -- some keyboard keys — B is 45, the keyboard's R (delete), A is 21 (Shift), X is 22 (Space) — so
            -- each reads only while it is the one in use (WhipLastInputIsPad, client/controller.lua).
            local pad = WhipLastInputIsPad()

            local moveSpeed = DE_MOVE_SPEED * deSpeed
            local fwdV, rightV = vector3(fwdX, fwdY, fwdZ), vector3(rightX, rightY, 0.0)
            if pad then
                -- The left stick flies (by how far it is pushed), RT up and LT down, RB faster.
                if IsDisabledControlPressed(0, DE_PAD_RB) then moveSpeed = moveSpeed * DE_FAST_MULT end
                local sx, sy = GetDisabledControlNormal(0, 30), GetDisabledControlNormal(0, 31)
                if math.abs(sx) < DE_PAD_DEAD then sx = 0.0 end
                if math.abs(sy) < DE_PAD_DEAD then sy = 0.0 end
                local rt, lt = WhipPadTrigger('rt', 0.0), WhipPadTrigger('lt', 0.0)
                deVelocity = deVelocity + (fwdV * -sy + rightV * sx + vector3(0, 0, rt - lt)) * moveSpeed * dt
            else
                if IsDisabledControlPressed(0, 21) then moveSpeed = moveSpeed * DE_FAST_MULT end
                if IsDisabledControlPressed(0, 32) then deVelocity = deVelocity + fwdV * moveSpeed * dt end
                if IsDisabledControlPressed(0, 33) then deVelocity = deVelocity - fwdV * moveSpeed * dt end
                if IsDisabledControlPressed(0, 35) then deVelocity = deVelocity + rightV * moveSpeed * dt end
                if IsDisabledControlPressed(0, 34) then deVelocity = deVelocity - rightV * moveSpeed * dt end
                if IsDisabledControlPressed(0, 22) then deVelocity = deVelocity + vector3(0, 0, moveSpeed) * dt end
                if IsDisabledControlPressed(0, 36) then deVelocity = deVelocity - vector3(0, 0, moveSpeed) * dt end
            end

            deVelocity = deVelocity * (1.0 - DE_DAMPING * dt)
            camCoords = camCoords + deVelocity * dt

            -- The mouse moves the view by how far it moved this frame; the right stick by how far it is held
            -- over, per second.
            local lookX, lookY
            if pad then
                lookX = GetDisabledControlNormal(0, 1) * DE_PAD_LOOK * dt
                lookY = GetDisabledControlNormal(0, 2) * DE_PAD_LOOK * dt
            else
                lookX = GetDisabledControlNormal(0, 1) * DE_SENSITIVITY
                lookY = GetDisabledControlNormal(0, 2) * DE_SENSITIVITY
            end
            local newPitch = math.max(-89.0, math.min(89.0, camRot.x - lookY))
            local newYaw   = camRot.z - lookX
            camRot = vector3(newPitch, 0.0, newYaw)

            -- Speed adjust: Shift + the wheel on a keyboard, a step per D-pad up / down press on a pad.
            if pad then
                if IsDisabledControlJustPressed(0, DE_PAD_UP) then deSpeed = math.min(10, deSpeed * 1.5) end
                if IsDisabledControlJustPressed(0, DE_PAD_DOWN) then deSpeed = math.max(0.1, deSpeed / 1.5) end
            elseif IsDisabledControlPressed(0, 21) then
                if IsDisabledControlPressed(0, 241) then deSpeed = math.min(10, deSpeed + 0.2) end
                if IsDisabledControlPressed(0, 242) then deSpeed = math.max(0.1, deSpeed - 0.2) end
            end

            SetCamCoord(deCam, camCoords.x, camCoords.y, camCoords.z)
            SetCamRot(deCam, camRot.x, camRot.y, camRot.z, 2)
            SetFocusPosAndVel(camCoords.x, camCoords.y, camCoords.z, 0.0, 0.0, 0.0)

            frameCount = frameCount + 1
            if frameCount >= 100 then
                frameCount = 0
                SetEntityCoordsNoOffset(ped, camCoords.x, camCoords.y, camCoords.z, false, false, false)
            end

            -- WHAT THE CAMERA IS ON: the ray (walls stop it: the world and objects), else a saved door near the
            -- line of sight (see "What is drawn", above).
            local now = GetGameTimer()
            if now >= deNearAt then
                deNearAt = now + 250
                deNearby(camCoords)
            end
            if now >= deReadAt then deRead() end

            local endPos = camCoords + vector3(fwdX, fwdY, fwdZ) * 40.0
            local _, hit, _, _, hitEntity = GetShapeTestResult(
                StartShapeTestRay(camCoords.x, camCoords.y, camCoords.z, endPos.x, endPos.y, endPos.z, 1 + 16, ped, 0)
            )
            local aimEnt = ((hit == 1 or hit == true) and hitEntity and hitEntity ~= 0 and DoesEntityExist(hitEntity)
                and GetEntityType(hitEntity) == 3) and hitEntity or nil
            local aimDoor = nil   -- the saved door aimed at: its whole record (or the client's, until the list has it)
            if aimEnt then
                local live = GetClientDoor({ entity = aimEnt })
                if live then aimDoor = deById[live.doorId] or live end
            else
                aimDoor = deNearestToSight(camCoords, fwdX, fwdY, fwdZ)
                if aimDoor then
                    aimEnt = DoorLeaf.entity(deSlot(aimDoor.doorId), aimDoor.model, aimDoor.x, aimDoor.y, aimDoor.z)
                end
            end

            -- Every saved door near, on its leaf; the aimed one brighter. The first of a link pulses purple.
            local pulse = 0.5 + 0.5 * math.sin(now / 250.0)
            for _, d in ipairs(deNear) do
                local isAim = aimDoor ~= nil and aimDoor.doorId == d.doorId
                local isLink = deLink1 == d.doorId
                local rgb = isLink and DE_RGB.link or deManaged(d) and DE_RGB.managed or DE_RGB.saved
                local ent = isAim and aimEnt or DoorLeaf.entity(deSlot(d.doorId), d.model, d.x, d.y, d.z)
                local fill, edge = 55, 170
                if isAim then fill, edge = 120, 255
                elseif isLink then fill, edge = math.floor(70 + 60 * pulse), 255 end
                DoorLeaf.draw(d.model, ent, d.x, d.y, d.z, d.heading, rgb, fill, edge)
                local o = d.linkedDoorId and deById[d.linkedDoorId]
                if o and d.linkedDoorId > d.doorId then
                    local a, b = d._body, deBody(o)
                    DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 255, 255, 255, 200)
                end
            end
            -- A saved door the list does not have yet (just made): on its object.
            if aimDoor and aimEnt and not deById[aimDoor.doorId] then
                local p = GetEntityCoords(aimEnt)
                DoorLeaf.draw(GetEntityModel(aimEnt), aimEnt, p.x, p.y, p.z, GetEntityHeading(aimEnt), DE_RGB.saved, 120, 255)
            end
            -- The wizard's leaves, blue; an object that is not a door yet, amber.
            local leafAt = deLeafOf(aimEnt)
            if deCapture then
                for i, l in ipairs(deCapture.leaves) do
                    local ent = DoorLeaf.entity(l, l.model, l.x, l.y, l.z)
                    DoorLeaf.draw(l.model, ent, l.x, l.y, l.z, l.heading, DE_RGB.picked, i == leafAt and 140 or 90, 255)
                end
            end
            if aimEnt and not aimDoor and not leafAt then
                local p = GetEntityCoords(aimEnt)
                DoorLeaf.draw(GetEntityModel(aimEnt), aimEnt, p.x, p.y, p.z, GetEntityHeading(aimEnt), DE_RGB.new, 110, 255)
            end
            ---@cast deOutline -nil   (made before the editor opens, gone after it shuts)
            deOutline.set(aimEnt)

            -- Its name over its top.
            if aimDoor then
                local b = deById[aimDoor.doorId] and deBody(aimDoor)
                    or DoorLeaf.body(aimDoor.model, aimDoor.x, aimDoor.y, aimDoor.z, aimEnt and GetEntityHeading(aimEnt) or 0.0)
                deLabel(b.x, b.y, b.top + 0.3, ('#%d · %s · %s'):format(aimDoor.doorId, aimDoor.label or 'Door',
                    aimDoor.locked and 'locked' or 'unlocked'))
                if deLink1 and deLink1Body and aimDoor.doorId ~= deLink1 then
                    DrawLine(deLink1Body.x, deLink1Body.y, deLink1Body.z, b.x, b.y, b.z, 192, 132, 252, 220)
                end
            elseif aimEnt then
                local p = GetEntityCoords(aimEnt)
                local b = DoorLeaf.body(GetEntityModel(aimEnt), p.x, p.y, p.z, GetEntityHeading(aimEnt))
                deLabel(b.x, b.y, b.top + 0.3, leafAt and ('Leaf %d'):format(leafAt) or 'Not a door yet')
            end

            -- THE ACTIONS, each from the device in use (`pad`, above). Not while a dialog is up (the link's or the
            -- exit's Confirm, which a pad answers with A and B too), nor with LB held (the pad's combo key).
            local busy = UI.IsBusy() or (pad and WhipPadModHeld)
            local function pressed(key, button)
                if busy then return false end
                if pad then return IsDisabledControlJustPressed(0, button) end
                return IsDisabledControlJustPressed(0, key)
            end

            if deCapture then
                -- PICKING FOR THE WIZARD: G / A take the door or let a leaf go, Enter / ☰ done, Esc / B back.
                local leaves = deCapture.leaves
                if pressed(47, DE_PAD_A) then
                    if aimDoor then
                        deSay(('That is door #%d already: open it in the list'):format(aimDoor.doorId), 'err')
                    elseif leafAt then
                        table.remove(leaves, leafAt)
                        deSay(#leaves == 0 and 'Let go: nothing is taken' or 'Let go: a single door now', 'info')
                    elseif not aimEnt then
                        deSay('Aim at the door first', 'err')
                    elseif #leaves >= 2 then
                        deSay('A door has two leaves at most: let one go first', 'warn')
                    else
                        local p = GetEntityCoords(aimEnt)
                        local model = PropertyMath.signedHash(GetEntityModel(aimEnt))
                        leaves[#leaves + 1] = { model = model, x = p.x, y = p.y, z = p.z, heading = GetEntityHeading(aimEnt),
                                                entity = aimEnt }
                        -- Anything may be taken (whip's doors take any model), but one not shaped like a door is said.
                        local doorLike = Interior.doorShape(model) ~= nil
                        if not doorLike then
                            deSay((#leaves == 2 and 'Both leaves taken' or 'Taken')
                                .. '. It is not shaped like a door: make sure it opens', 'warn')
                        elseif #leaves == 2 then
                            deSay('Both leaves: they open and lock together. Enter is Done', 'ok')
                        else
                            deSay('Taken. A double door? Take its other leaf too', 'ok')
                        end
                    end
                end
                local done
                if pad then done = pressed(nil, 199)
                else done = pressed(201, nil) or pressed(18, nil) end
                if done then
                    if #leaves == 0 then
                        deSay('Take a door first, or go back', 'err')
                    else
                        deCapture.done = true
                        CreateThread(ExitDoorEditor)
                    end
                end
                if pressed(200, DE_PAD_B) then
                    CreateThread(ExitDoorEditor)
                end
            else
                -- Save door
                if pressed(47, DE_PAD_A) and aimEnt then
                    if aimDoor then
                        deSay('That door is saved already', 'info')
                    else
                        local ePos = GetEntityCoords(aimEnt)
                        TriggerServerEvent('whip_core:server:doorCreate', {
                            model   = GetEntityModel(aimEnt),
                            x       = ePos.x,
                            y       = ePos.y,
                            z       = ePos.z,
                            heading = GetEntityHeading(aimEnt),
                            label   = 'Door',
                        })
                        deSay('Door saved')
                        deReadAt = now + 800   -- lit green once the list has it
                    end
                end

                -- Link doors.
                if pressed(38, DE_PAD_X) then
                    if not deLink1 then
                        if aimDoor then
                            deLink1 = aimDoor.doorId
                            deLink1Body = deById[aimDoor.doorId] and deBody(aimDoor)
                                or DoorLeaf.body(aimDoor.model, aimDoor.x, aimDoor.y, aimDoor.z, aimEnt and GetEntityHeading(aimEnt) or 0.0)
                            deSay('Door #' .. aimDoor.doorId .. ' picked: aim at the second door', 'info')
                        elseif aimEnt then
                            deSay('Save this door first, then link it', 'warn')
                        else
                            deSay('Aim at a saved door first', 'warn')
                        end
                    else
                        if aimDoor and aimDoor.doorId ~= deLink1 then
                            deLink2 = aimDoor.doorId
                            CreateThread(function()
                                local confirmed = UI.Confirm('Link Doors?',
                                    'Link Door #' .. deLink1 .. ' with Door #' .. deLink2 .. '?\nLocking one will lock the other.')
                                if confirmed then
                                    TriggerServerEvent('whip_core:server:doorLink', deLink1, deLink2)
                                    deSay('Doors #' .. deLink1 .. ' and #' .. deLink2 .. ' linked')
                                    deReadAt = GetGameTimer() + 800
                                else
                                    deSay('Link cancelled', 'info')
                                end
                                deLink1 = nil
                                deLink1Body = nil
                                deLink2 = nil
                            end)
                        elseif aimDoor then
                            deSay('That is the same door: aim at another, or cancel', 'warn')
                        elseif aimEnt then
                            deSay('Save this door first, then link it', 'warn')
                        else
                            deSay('Aim at a saved door', 'warn')
                        end
                    end
                end

                -- Cancel the link, or leave the editor
                if pressed(200, DE_PAD_B) then
                    if deLink1 then
                        deLink1 = nil
                        deLink1Body = nil
                        deLink2 = nil
                        deSay('Link cancelled', 'info')
                    else
                        CreateThread(function()
                            local confirmed = UI.Confirm('Exit Door Editor?', 'Saved doors persist in the database.')
                            if confirmed then ExitDoorEditor() end
                        end)
                    end
                end

                -- Delete door
                if pressed(45, DE_PAD_Y) and (aimEnt or aimDoor) then
                    if aimDoor then
                        TriggerServerEvent('whip_core:server:doorDelete', aimDoor.doorId)
                        deSay('Door #' .. aimDoor.doorId .. ' deleted')
                        deReadAt = now + 800
                    else
                        deSay('That door is not saved', 'info')
                    end
                end
            end

            -- The card, ten times a second at most; EditorHud sends nothing when nothing changed.
            if frameCount % 6 == 0 then EditorHud.update(deCard(aimDoor, aimEnt)) end
            end)
            if not frameOk then
                print('[whip_core:zones] the door editor errored and was closed: ' .. tostring(frameErr))
                pcall(ExitDoorEditor)
            end

            Wait(0)
        else
            break
        end
    end
    deLoopRunning = false
end

startDeLoop = function()
    if deLoopRunning then return end
    deLoopRunning = true
    CreateThread(deLoop)
end

-- ============================================
-- Door Manager — NUI Callbacks
-- ============================================

RegisterNUICallback('dmEnterEditor', function(_, cb)
    -- Same suspend contract as the zone editor: the /whip panel hides, focus goes to
    -- the in-world door editor, and the editor's exit path resumes the panel.
    WhipPanelSuspend()
    EnterDoorEditor()
    cb('ok')
end)

-- (dmCloseDoorManager retired with the standalone panel — the /whip shell owns close.)

-- ---- The doors wizard (html/js/wp/doors.js) ----
--
-- dwPick opens the editor to pick the door (see "Picking for the wizard", above); the leaves come back as 'wizPick'
-- when it closes. dwCreate saves the door whole (whip_core:doorWizardCreate, server/doors.lua), and the list is sent
-- again so the page can open on it.

RegisterNUICallback('dwPick', function(data, cb)
    if deActive then cb({ ok = false, why = 'The door editor is open already' }) return end
    if zeActive or PropertyEditorActive then cb({ ok = false, why = 'Something else is using the world editor' }) return end
    local leaves = {}
    for _, l in ipairs(type(data) == 'table' and type(data.leaves) == 'table' and data.leaves or {}) do
        local m, x, y, z = tonumber(l.model), tonumber(l.x), tonumber(l.y), tonumber(l.z)
        if m and x and y and z and #leaves < 2 then
            leaves[#leaves + 1] = { model = m, x = x + 0.0, y = y + 0.0, z = z + 0.0, heading = (tonumber(l.heading) or 0.0) + 0.0 }
        end
    end
    WhipPanelSuspend()
    EnterDoorEditor({ leaves = leaves })
    cb({ ok = true })
end)

--- The jobs a door can be kept for: { { key, name } }.
RegisterNUICallback('dwJobs', function(_, cb)
    CreateThread(function()
        local res = Callback('whip_core:doorWizardJobs')
        cb(type(res) == 'table' and res or {})
    end)
end)

RegisterNUICallback('dwCreate', function(data, cb)
    CreateThread(function()
        local res = Callback('whip_core:doorWizardCreate', data)
        if type(res) ~= 'table' then res = { ok = false, why = 'No answer from the server' } end
        cb(res)
        if res.ok then SendNUIMessage({ action = 'dmRefresh', doors = GetAllDoorsForTool() }) end
    end)
end)

--- To a leaf the wizard has (not saved yet, so not dmTeleport's).
RegisterNUICallback('dwTeleport', function(data, cb)
    local x, y, z = tonumber(data and data.x), tonumber(data and data.y), tonumber(data and data.z)
    if x and y and z then SetEntityCoords(PlayerPedId(), x + 0.0, y + 0.0, z + 0.0, false, false, false, false) end
    cb('ok')
end)

RegisterNUICallback('dmToggleLock', function(data, cb)
    if data.doorId then
        -- The SERVER computes the new state: the client's IsDoorLocked is stale for a far door
        -- (lock changes are cell-scoped).
        TriggerServerEvent('whip_core:server:doorToggleLocked', data.doorId)
    end
    Wait(200)
    SendNUIMessage({ action = 'dmRefresh', doors = GetAllDoorsForTool() })
    cb('ok')
end)

RegisterNUICallback('dmTeleport', function(data, cb)
    local allDoors = GetAllDoorsForTool()
    for _, d in ipairs(allDoors) do
        if d.doorId == data.doorId then
            SetEntityCoords(PlayerPedId(), d.x, d.y, d.z, false, false, false, false)
            break
        end
    end
    cb('ok')
end)

RegisterNUICallback('dmDeleteDoor', function(data, cb)
    if data.doorId then
        TriggerServerEvent('whip_core:server:doorDelete', data.doorId)
    end
    Wait(300)
    SendNUIMessage({ action = 'dmRefresh', doors = GetAllDoorsForTool() })
    cb('ok')
end)

RegisterNUICallback('dmUnlinkDoor', function(data, cb)
    if data.doorId then
        TriggerServerEvent('whip_core:server:doorUnlink', data.doorId)
    end
    Wait(300)
    SendNUIMessage({ action = 'dmRefresh', doors = GetAllDoorsForTool() })
    cb('ok')
end)

RegisterNUICallback('dmReleaseDoor', function(data, cb)
    if data.doorId then
        -- The server decides: only a door whose managing resource has stopped can be released here.
        TriggerServerEvent('whip_core:server:doorRelease', data.doorId)
    end
    Wait(300)
    SendNUIMessage({ action = 'dmRefresh', doors = GetAllDoorsForTool() })
    cb('ok')
end)

RegisterNUICallback('dmUpdateDoor', function(data, cb)
    if data.doorId and data.field then
        TriggerServerEvent('whip_core:server:doorUpdate', data.doorId, { [data.field] = data.value })
    end
    Wait(200)
    SendNUIMessage({ action = 'dmRefresh', doors = GetAllDoorsForTool() })
    cb('ok')
end)

RegisterNUICallback('dmSetRequirement', function(data, cb)
    if data.doorId then
        local allDoors = GetAllDoorsForTool()
        for _, d in ipairs(allDoors) do
            if d.doorId == data.doorId then
                local req = d.requirements or {}
                req[data.reqKey] = data.value
                if data.value == nil or (type(data.value) == 'table' and #data.value == 0) then
                    req[data.reqKey] = nil
                end
                TriggerServerEvent('whip_core:server:doorUpdate', data.doorId, { requirements = req })
                break
            end
        end
    end
    Wait(200)
    SendNUIMessage({ action = 'dmRefresh', doors = GetAllDoorsForTool() })
    cb('ok')
end)

RegisterNUICallback('dmToggleLockpick', function(data, cb)
    if data.doorId then
        local allDoors = GetAllDoorsForTool()
        for _, d in ipairs(allDoors) do
            if d.doorId == data.doorId then
                local req = d.requirements or {}
                req.lockpick = not req.lockpick
                TriggerServerEvent('whip_core:server:doorUpdate', data.doorId, { requirements = req })
                break
            end
        end
    end
    Wait(200)
    SendNUIMessage({ action = 'dmRefresh', doors = GetAllDoorsForTool() })
    cb('ok')
end)

-- ============================================
-- Register with the /whip panel
-- ============================================
--
-- Registered HERE rather than in tools/panel_sections/ because both payload builders
-- (GetAllZones, GetAllDoorsForTool) are file-locals of this runtime — the same
-- own-the-private-state rule the Sentinel truth functions follow. Both sections are
-- client-local: no server round-trip, the data is already in this Lua state.

PanelSections['zones'] = {
    enter = function()
        WhipPanelData('zones', 'all', { zones = GetAllZones() })
    end,
    leave = function() end,
}

PanelSections['doors'] = {
    enter = function()
        DoorManagerOpen = true
        WhipPanelData('doors', 'all', { doors = GetAllDoorsForTool() })
    end,
    leave = function()
        DoorManagerOpen = false
    end,
}

-- THE EDITORS END WITH THE RESOURCE. Both hide, freeze and proof the admin's ped and fly a
-- scripted camera, and only their own Esc undoes that.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if not (zeActive or deActive) then return end
    zeActive, deActive = false, false
    ZoneEditorActive, DoorEditorActive = false, false
    RenderScriptCams(false, false, 0, true, false)
    if zeCam then DestroyCam(zeCam, false) zeCam = nil end
    if deCam then DestroyCam(deCam, false) deCam = nil end
    PedHold.release('zoneEditor')   -- client/ped_hold.lua lets go of every hold as whip_core stops anyway
    PedHold.release('doorEditor')
    SetLocalPlayerVisibleLocally(true)
end)
