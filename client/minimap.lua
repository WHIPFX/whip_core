-- ============================================
-- THE MINIMAP — whip's own, in GTA's radar's place
-- ============================================
--
-- GTA's radar is not shown (client/hud.lua keeps it hidden, but for the /radardebug tuner). whip's 3D map stands in
-- its place, in the HUD's map box at the bottom left: html/js/minimap.js draws it, from 3D Clanker's 3D map. hud.lua
-- decides WHEN, as it decided for the radar (MinimapShow: a vehicle, or on foot by the player's choice, with no screen
-- up). This file feeds the page while it shows, and nothing runs while it does not:
--
--   minimapPose   the player and the camera, as often as the player's Minimap frame rate (map.fps, below), and only
--                 when something moved
--   minimapMoves  the blips on moving things (a car, a ped), ten times a second (MOVES_MS)
--   minimapData   every blip (a scan spread over frames), the GPS line and the waypoint, every DATA_MS
--   minimapBox    the box — the black skin's frame box (client/hud_skin.lua's `frame`, at this screen's shape and
--                 safe zone) for every look — its shape and border, and the dial's speed unit, when they change
--
-- The blips are found as the pause menu's map finds them (client/pause.lua): every sprite asked for its blips. Here
-- the scan is spread over frames (SPRITES_PER_FRAME), as it runs all the while the minimap is up, and a blip on a
-- moving thing is followed between scans. A blip the game made short-range shows only inside the box; any other is
-- pinned to its edge when far (minimap.js), as on GTA's radar. A blip's rotation and flashing go with it.
--
-- THE PLAYER'S SETTINGS are declared here (the pause menu's Server Settings → Minimap, client/player_prefs.lua), all
-- read by the page (page = true). The Minimap tab shows a preview of the minimap on a drive (html/js/minimap.js
-- MinimapPreview), and while it is up this file sends it the blips, route and waypoint round the player
-- ('minimapPreview'). /minimapblips says what the blip scan finds.

local MOVES_MS = 100            -- the moving blips
local DATA_MS = 1500            -- every blip, the route and the waypoint
local SPRITES_PER_FRAME = 100   -- the blip scan, this many sprites a frame
local MAX_SPRITE = 1000         -- the highest sprite asked about (GTA's go past 900)
local MOVED_M = 0.5             -- a moving blip is sent again once it has moved this far

--- Sprites that are not places on the minimap: the player's own arrow (6), north (7), the waypoint (8, sent on its
--- own), the wanted and area circles (4, 5, 9, 10), noise and status rings. client/pause.lua skips the same.
local SKIP_SPRITE = { [4] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true,
    [10] = true, [161] = true, [163] = true, [164] = true }

--- Display modes that never show: 0, 1 and 7. NOT 3 and 4, which the natives' table calls "the big map only": 4 is
--- what most scripts set for an ordinary blip, and GTA shows it on the radar too. Leaving them out hid every blip
--- but the waypoint (Josh, 28 Oct).
local NEVER_SHOWN = { [0] = true, [1] = true, [7] = true }

--- What a blip is attached to (GetBlipInfoIdType) when that thing can move: a vehicle, a ped, an object, a pickup.
local MOVING = { [1] = true, [2] = true, [3] = true, [6] = true }

--- HUD_COLOUR_WAYPOINT: the waypoint, its blip and the GPS line (whip blue with the black HUD: client/hud_skin.lua).
local ROUTE_HUD_COLOUR = 142

--- Points along the GPS route, this far apart and this many: 3 km ahead, past what the box shows at any speed.
local ROUTE_STEP, ROUTE_MAX = 20.0, 150

--- The box when hud_skin.lua is not there to ask: its shipped frame (posX, posY up from the bottom, sizeX, sizeY).
local FRAME_DEFAULT = { 0.0060, 0.0700, 0.1720, 0.1655 }

-- ---- the player's settings (Server Settings → Minimap) ----
--
-- Read by html/js/minimap.js (page = true) as they change; the views are metres across the box, so every screen shows
-- the same; the speeds are in the dial's unit (Config.VehicleHud.speedUnit, sent with the box). The defaults are the
-- camera's own as 3D Clanker tuned it, at Josh's 330 px box.

local SPEED_UNIT = (Config.VehicleHud and Config.VehicleHud.speedUnit == 'kmh') and 'kmh' or 'mph'
local SPEED_LABEL = SPEED_UNIT == 'kmh' and 'km/h' or 'mph'
local KMH = SPEED_UNIT == 'kmh'

--- THE SERVER MAY DECIDE THEM ALL (/whip → Config → Map options → Same minimap for everyone, Config.MapOptions):
--- each row's `forced` answers the server's value for it then, and nil while each player chooses.
---@param field string  its name in Config.MapOptions.minimap
local function server(field)
    return function()
        local o = Config.MapOptions
        if not (o and o.forceMinimap == true and type(o.minimap) == 'table') then return nil end
        return o.minimap[field]
    end
end

-- How often the minimap is drawn while it moves. The page draws at most this often, and the pose is sent as often,
-- since the map only turns with the camera when a pose arrives. Nothing either way while nothing moves. A Wait is at
-- least a frame, so above the game's own frame rate it is the game's.
PlayerPrefs.define({
    key = 'map.fps', group = 'Minimap', type = 'choice', label = 'Frame rate',
    help = 'How often the minimap is drawn while it moves. Higher is smoother and costs more; standing still costs nothing.',
    options = { { value = 120, label = '120' }, { value = 60, label = '60' }, { value = 45, label = '45' },
        { value = 30, label = '30' }, { value = 15, label = '15' } },
    default = 60,
    page = true, forced = server('fps'),
})

-- The border round it, with the black HUD (client/hud_skin.lua draws the game's own frame only for /radardebug):
--   true       the white frame: black, white, black from the map's edge out
--   'outline'  an empty gauge's rim: the track's faint grey, then the black edge (css/hud-skin.css)
--   false      none
-- true and false are the values this row had when it was a switch, so a player's old choice still holds.
PlayerPrefs.define({
    key = 'map.border', group = 'Minimap', type = 'choice', label = 'Border',
    help = 'Round the minimap: the white frame, a thin outline like an empty gauge\'s, or nothing.',
    options = { { value = true, label = 'Full' }, { value = 'outline', label = 'Outline' }, { value = false, label = 'Off' } },
    default = true, forced = server('border'),
    visible = function() return Config.HudSkin == 'black' end,
})

PlayerPrefs.define({
    key = 'mm.northUp', group = 'Minimap', type = 'toggle', label = 'North always up',
    help = 'The minimap stays north-up instead of turning with your camera. Your arrow still shows which way you face.',
    default = false, page = true, forced = server('northUp'),
})

PlayerPrefs.define({
    key = 'mm.centre', group = 'Minimap', type = 'toggle', label = 'You in the centre',
    help = 'You at the middle of the minimap, rather than a little below it with more of the road ahead showing.',
    default = false, page = true, forced = server('centre'),
})

PlayerPrefs.define({
    key = 'mm.markerSize', group = 'Minimap', type = 'slider', label = 'Marker size',
    help = 'How big the blips, the waypoint, north and your arrow are on the minimap.',
    min = 50, max = 200, step = 10, unit = '%', default = 100, page = true, forced = server('markerSize'),
})

PlayerPrefs.define({
    key = 'mm.markersUpright', group = 'Minimap', type = 'toggle', label = 'Upright markers',
    help = 'On: every marker on the minimap faces up, never sideways or upside down, however the map turns. Off: they '
        .. 'turn with the map, and one the game points (a car\'s arrow) points its way.',
    default = true, page = true, forced = server('markersUpright'),
})

PlayerPrefs.define({
    key = 'mm.viewFoot', group = 'Minimap', type = 'slider', label = 'View on foot',
    help = 'How much of the map shows on foot: metres across the minimap.',
    min = 80, max = 600, step = 10, unit = 'm', default = 230, page = true, forced = server('viewFoot'),
})

PlayerPrefs.define({
    key = 'mm.viewSlow', group = 'Minimap', type = 'slider', label = 'View in a vehicle, slow',
    help = 'How much shows in a vehicle going slower than "Zoom out from": the closest the minimap comes in a vehicle.',
    min = 100, max = 1000, step = 10, unit = 'm', default = 290, page = true, forced = server('viewSlow'),
})

PlayerPrefs.define({
    key = 'mm.viewFast', group = 'Minimap', type = 'slider', label = 'View at top speed',
    help = 'How much shows at "Furthest from" and faster: the furthest the minimap goes out.',
    min = 200, max = 3000, step = 50, unit = 'm', default = 800, page = true, forced = server('viewFast'),
})

PlayerPrefs.define({
    key = 'mm.speedFrom', group = 'Minimap', type = 'slider', label = 'Zoom out from',
    help = 'The speed the minimap starts to zoom out at. Slower than this it stays at its closest.',
    min = 0, max = KMH and 160 or 100, step = 5, unit = SPEED_LABEL, default = 0, page = true, forced = server('speedFrom'),
})

PlayerPrefs.define({
    key = 'mm.speedTo', group = 'Minimap', type = 'slider', label = 'Furthest from',
    help = 'The speed the minimap is all the way out at (View at top speed). Faster stays there.',
    min = KMH and 30 or 20, max = KMH and 320 or 200, step = 5, unit = SPEED_LABEL,
    default = KMH and 160 or 100, page = true, forced = server('speedTo'),
})

PlayerPrefs.define({
    key = 'mm.tiltFoot', group = 'Minimap', type = 'slider', label = 'Tilt on foot',
    help = 'How far the minimap leans back on foot: 0 is straight down.',
    min = 0, max = 60, step = 1, unit = '°', default = 0, page = true, forced = server('tiltFoot'),
})

PlayerPrefs.define({
    key = 'mm.tiltVehicle', group = 'Minimap', type = 'slider', label = 'Tilt in a vehicle',
    help = 'How far it leans back in a vehicle (when slow, if the tilt changes with speed): 0 is straight down.',
    min = 0, max = 70, step = 1, unit = '°', default = 38, page = true, forced = server('tiltVehicle'),
})

PlayerPrefs.define({
    key = 'mm.tiltWithSpeed', group = 'Minimap', type = 'toggle', label = 'Tilt changes with speed',
    help = 'In a vehicle the tilt moves from "Tilt in a vehicle" to "Tilt at top speed" as you go faster: more, or less.',
    default = false, page = true, forced = server('tiltWithSpeed'),
})

PlayerPrefs.define({
    key = 'mm.tiltFast', group = 'Minimap', type = 'slider', label = 'Tilt at top speed',
    help = 'The tilt at "Furthest from" and faster, when the tilt changes with speed.',
    min = 0, max = 70, step = 1, unit = '°', default = 50, page = true, forced = server('tiltFast'),
    visible = function() return PlayerPrefs.get('mm.tiltWithSpeed') == true end,
})

local poseMs = 16               -- the pose, at most this often: 1000 / map.fps

local function readFps()
    poseMs = math.floor(1000 / (tonumber(PlayerPrefs.get('map.fps')) or 60))
end
readFps()
PlayerPrefs.onChange('map.fps', readFps)

-- The server's Map options changed (/whip → Config): every row it may decide is read again, so the minimap and
-- the page follow at once (client/hud.lua's on-foot and in-vehicle rows too).
local DECIDED = { 'map.onFoot', 'map.inVehicle', 'map.fps', 'map.border', 'mm.northUp', 'mm.centre', 'mm.markerSize',
    'mm.markersUpright', 'mm.viewFoot', 'mm.viewSlow', 'mm.viewFast', 'mm.speedFrom', 'mm.speedTo', 'mm.tiltFoot',
    'mm.tiltVehicle', 'mm.tiltWithSpeed', 'mm.tiltFast' }
Settings.onChange('MapOptions', function() PlayerPrefs.recheck(DECIDED) end)

local shown = false
local feedGen = 0               -- each show is a new generation; a loop from an older one stops
local previewGen = 0            -- the same for the Server Settings preview's feed
local movers = {}               -- the blips on moving things, from the last scan
local moverAt = {}              -- [blip] = { x, y } as last sent
local sentBox = nil

-- ---- reading GTA ----

--- GET_BLIP_HUD_COLOUR, by name or, on a client whose Lua lacks it, by hash (as client/pause.lua).
local blipHudColour = GetBlipHudColour or function(blip)
    return Citizen.InvokeNative(0x729B5F1EFBC0AAEE, blip, Citizen.ResultAsInteger())
end

local hexCache = {}

--- A HUD colour as '#rrggbb'. `fresh`: not from the cache (the waypoint's colour changes with the HUD's look).
local function hudHex(hud, fresh)
    local h = not fresh and hexCache[hud]
    if h then return h end
    local r, g, b = GetHudColour(hud)
    local hex = ('#%02x%02x%02x'):format(r or 255, g or 255, b or 255)
    if not fresh then hexCache[hud] = hex end
    return hex
end

--- A number JSON can carry: GTA answers NaN or an infinity for a blip it cannot place, and FiveM then drops the WHOLE
--- message (client/pause.lua says more).
local function finite(v)
    return type(v) == 'number' and v == v and v > -math.huge and v < math.huge
end

local function tenth(v) return math.floor(v * 10 + 0.5) / 10 end

--- A blip's rotation (degrees, GTA's sense), or nil for none.
local function rotationOf(b)
    local r = GetBlipRotation(b)
    return (finite(r) and r ~= 0) and r or nil
end

--- GET_POS_ALONG_GPS_TYPE_ROUTE, under whichever name this client's Lua has (as client/pause.lua).
local posAlongRoute = GetPosAlongGpsTypeRoute or GetGpsWaypointRouteEnd or function(fromPlayer, dist, slot)
    return Citizen.InvokeNative(0xF3162836C28F9DA5, Citizen.PointerValueVector(), fromPlayer, dist, slot,
        Citizen.ReturnResultAnyway())
end

--- The GPS route from the player, { x, y, z } every ROUTE_STEP metres, or nil. Slot 0 is the waypoint's, 1 a blip's.
local function readRoute(slot)
    local pts, lx, ly = {}, nil, nil
    for i = 0, ROUTE_MAX do
        local ok, p = posAlongRoute(true, i * ROUTE_STEP, slot)
        if ok == 0 then ok = false end   -- by hash, the answer is a number
        if not ok or type(p) ~= 'vector3' and type(p) ~= 'table' then break end
        if not finite(p.x) or not finite(p.y) or not finite(p.z) or (p.x == 0.0 and p.y == 0.0) then break end
        if lx and math.abs(p.x - lx) < 0.5 and math.abs(p.y - ly) < 0.5 then break end   -- past the end
        pts[#pts + 1] = { tenth(p.x), tenth(p.y), tenth(p.z) }
        lx, ly = p.x, p.y
    end
    return #pts > 1 and pts or nil
end

--- Every blip the radar would show, scanned SPRITES_PER_FRAME sprites a frame, into `list`: the calling loop's own,
--- kept between scans and REFILLED, an entry per blip whose fields are written over (a scan a second made a table for
--- every blip on the map, the minimap's biggest share of the memory whip_core makes). Answers whether anything in it
--- changed, the blips on moving things, and where those are; nil if `alive()` turned false meanwhile.
---@param alive function
---@param list table  this loop's list, refilled in place
---@return boolean|nil changed
---@return table|nil movers
---@return table|nil moverAt  [blip] = { x, y }, the movers only
local function scanBlips(alive, list)
    local moving, at = {}, {}
    local n, changed = 0, false
    for s0 = 0, MAX_SPRITE, SPRITES_PER_FRAME do
        local cost = WhipCost.start()
        for sprite = s0, math.min(MAX_SPRITE, s0 + SPRITES_PER_FRAME - 1) do
            if not SKIP_SPRITE[sprite] then
                local b = GetFirstBlipInfoId(sprite)
                while DoesBlipExist(b) do
                    local display = GetBlipInfoIdDisplay(b)
                    if not NEVER_SHOWN[display] and GetBlipAlpha(b) > 0 then
                        local c = GetBlipInfoIdCoord(b)
                        if finite(c.x) and finite(c.y) then
                            local x, y = tenth(c.x), tenth(c.y)
                            local colour = hudHex(blipHudColour(b))
                            local short = IsBlipShortRange(b) and true or false
                            local rot = rotationOf(b)
                            local flash = IsBlipFlashing(b) and true or nil
                            n = n + 1
                            local e = list[n]
                            if not e then
                                e = {}
                                list[n] = e
                            end
                            if e.id ~= b or e.x ~= x or e.y ~= y or e.sprite ~= sprite or e.colour ~= colour
                                or e.short ~= short or e.rot ~= rot or e.flash ~= flash then
                                e.id, e.x, e.y, e.sprite, e.colour, e.short, e.rot, e.flash =
                                    b, x, y, sprite, colour, short, rot, flash
                                changed = true
                            end
                            if MOVING[GetBlipInfoIdType(b)] then
                                moving[#moving + 1] = b
                                at[b] = { x, y }
                            end
                        end
                    end
                    b = GetNextBlipInfoId(sprite)
                end
            end
        end
        WhipCost.stop('minimap: blip scan (a slice)', cost)
        Wait(0)
        if not alive() then return nil end
    end
    -- Fewer than last time: the rest go
    for i = #list, n + 1, -1 do
        list[i] = nil
        changed = true
    end
    return changed, moving, at
end

--- Two routes the same, point for point (readRoute's lists, or nil).
local function sameRoute(a, b)
    if a == nil or b == nil then return a == b end
    if #a ~= #b then return false end
    for i = 1, #a do
        local p, q = a[i], b[i]
        if p[1] ~= q[1] or p[2] ~= q[2] or p[3] ~= q[3] then return false end
    end
    return true
end

--- The waypoint, or FALSE when there is none (the page keeps what it has for a key a message leaves out).
local function readWaypoint()
    local wp = GetFirstBlipInfoId(8)
    if not DoesBlipExist(wp) then return false end
    local c = GetBlipInfoIdCoord(wp)
    if not finite(c.x) or not finite(c.y) then return false end
    return { x = c.x, y = c.y }
end

-- ---- the box ----

--- The box: the black skin's frame box at this screen's shape and safe zone, as client/hud_skin.lua works it out —
--- fractions of the screen, from the left and the top.
local function sendBox(force)
    local f = HudSkinGetFrame and HudSkinGetFrame() or FRAME_DEFAULT
    local w, h = GetActiveScreenResolution()
    local aspect = (h and h > 0) and (w / h) or (16 / 9)
    local xs = (16 / 9) / aspect
    local margin = (1.0 - (GetSafeZoneSize() or 1.0)) / 2
    -- The border round it: the black HUD's, as the player chose it (map.border, above).
    local border = 'none'
    if Config.HudSkin == 'black' then
        local b = PlayerPrefs.get('map.border')
        border = b == 'outline' and 'outline' or (b ~= false and 'full' or 'none')
    end
    local box = {
        left = margin + f[1] * xs, top = 1.0 - (margin + f[2]) - f[4], width = f[3] * xs, height = f[4],
        shape = Config.MinimapMask or 'rounded',
        border = border,   -- 'full' | 'outline' | 'none'
        speedUnit = SPEED_UNIT,
    }
    local key = ('%.4f %.4f %.4f %.4f %s %s'):format(box.left, box.top, box.width, box.height, box.shape, box.border)
    if key == sentBox and not force then return end
    sentBox = key
    box.action = 'minimapBox'
    SendNUIMessage(box)
end

-- A border chosen in Server Settings shows at once (on the preview too, where the minimap itself is hidden).
PlayerPrefs.onChange('map.border', function() sendBox(false) end)

-- ---- the feed ----

--- The player and the camera, only when something moved.
---
--- One message table, refilled: this runs about 50 times a second and on the move nearly every run sends, so a table a
--- run (or two) was the minimap's biggest share of the memory whip_core makes in a car. SendNUIMessage serialises it
--- before it returns, so it can be reused (as client/vehicles.lua's capsule payload is).
local _pose = { action = 'minimapPose' }
local function poseLoop(gen)
    local sent = false   -- nothing sent yet by this loop: the first pass always sends
    while gen == feedGen do
        local cost = WhipCost.start()
        local ped = PlayerPedId()
        local c = GetEntityCoords(ped)
        local veh = GetVehiclePedIsIn(ped, false)
        local inVeh = veh ~= 0
        local x, y = math.floor(c.x * 20 + 0.5) / 20, math.floor(c.y * 20 + 0.5) / 20
        local heading = tenth(GetEntityHeading(ped))
        -- The map turns with the gameplay camera, as GTA's radar does (degrees, GTA's sense, like a heading).
        local camYaw = tenth(GetGameplayCamRot(2).z)
        local speed = tenth(GetEntitySpeed(inVeh and veh or ped))
        local p = _pose
        if not sent or x ~= p.x or y ~= p.y or heading ~= p.heading or camYaw ~= p.camYaw
            or speed ~= p.speed or inVeh ~= p.inVehicle then
            sent = true
            p.x, p.y, p.heading, p.camYaw, p.speed, p.inVehicle = x, y, heading, camYaw, speed, inVeh
            p.vehicleClass = inVeh and GetVehicleClass(veh) or nil
            SendNUIMessage(p)
        end
        WhipCost.stop('minimap: pose', cost)
        Wait(poseMs)
    end
end

--- Where the blips on moving things are now, those that moved (and their rotation).
local function movesLoop(gen)
    while gen == feedGen do
        Wait(MOVES_MS)
        if gen ~= feedGen then return end
        local cost = WhipCost.start()
        local out = {}
        for i = 1, #movers do
            local b = movers[i]
            if DoesBlipExist(b) then
                local c = GetBlipInfoIdCoord(b)
                if finite(c.x) and finite(c.y) then
                    local was = moverAt[b]
                    if not was or math.abs(c.x - was[1]) > MOVED_M or math.abs(c.y - was[2]) > MOVED_M then
                        moverAt[b] = { c.x, c.y }
                        out[#out + 1] = { b, tenth(c.x), tenth(c.y), rotationOf(b) or 0 }
                    end
                end
            end
        end
        if #out > 0 then SendNUIMessage({ action = 'minimapMoves', m = out }) end
        WhipCost.stop('minimap: moving blips', cost)
    end
end

--- Every blip, the route and the waypoint, while `alive()`; and the box, if it moved. Sent only when one of them
--- changed (the page rebuilds the route's line and draws again on each): standing still costs nothing. A new loop
--- (shown again) sends once whatever.
local function dataLoop(alive)
    -- This loop's own: the blip list (refilled by each scan), the message (refilled; SendNUIMessage serialises it before
    -- it returns), and what was last sent of the rest, compared value for value (not as one JSON string a pass).
    local list = {}
    local msg = { action = 'minimapData', blips = list }
    local sent = false
    local lastRoute, lastColour, lastWx, lastWy = nil, nil, nil, nil
    while alive() do
        local changed, moving, at = scanBlips(alive, list)
        if changed == nil then return end
        movers, moverAt = moving --[[@as table]], at --[[@as table]]   -- they come with changed

        local cost = WhipCost.start()
        local route = readRoute(0) or readRoute(1)
        local colour = hudHex(ROUTE_HUD_COLOUR, true)
        local waypoint = readWaypoint()
        local wx, wy = waypoint and waypoint.x or false, waypoint and waypoint.y or false
        if not sameRoute(route, lastRoute) or colour ~= lastColour or wx ~= lastWx or wy ~= lastWy then
            changed = true
        end
        if changed or not sent then
            sent = true
            lastRoute, lastColour, lastWx, lastWy = route, colour, wx, wy
            msg.route, msg.colour, msg.waypoint = route or false, colour, waypoint
            SendNUIMessage(msg)
        end
        sendBox(false)
        WhipCost.stop('minimap: route, waypoint, send', cost)
        Wait(DATA_MS)
    end
end

--- Show whip's minimap, or put it away: client/hud.lua's radar decision. Change-gated, so it may be called every pass.
---@param on boolean
function MinimapShow(on)
    on = on and true or false
    if on == shown then return end
    shown = on
    feedGen = feedGen + 1
    SendNUIMessage({ action = 'minimapShow', on = on })
    if not on then return end
    local gen = feedGen
    local alive = function() return gen == feedGen end
    sendBox(true)
    CreateThread(function() poseLoop(gen) end)
    CreateThread(function() movesLoop(gen) end)
    CreateThread(function() dataLoop(alive) end)
end

-- The Server Settings page's preview is up ({ on = true }) or gone: the blips, route and waypoint round the player for
-- it, as the minimap gets them. The minimap itself is hidden while the pause menu is open, so the two never both run.
RegisterNUICallback('minimapPreview', function(data, cb)
    cb('ok')
    previewGen = previewGen + 1
    if type(data) ~= 'table' or data.on ~= true then return end
    local gen = previewGen
    sendBox(true)
    CreateThread(function() dataLoop(function() return gen == previewGen end) end)
end)
