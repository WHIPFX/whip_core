-- ============================================
-- PAUSE MENU — whip's own, in place of GTA's
-- ============================================
--
-- Esc, P or a pad's Start open whip's pause menu, never GTA's: the whip logo and Resume / Map /
-- Settings / Quit on the left, a map on the right. Map makes the map full screen (drag, zoom,
-- double-click for a waypoint, a legend). Settings is GTA's own settings in whip's look (client/game_settings.lua);
-- Quit leaves the server. The page is html/js/pause.js and pause-map.js.
--
-- The map is whip's, the data is GTA's. The picture is a tile set (whip_media_map/map/whip). What is
-- on it comes from the game, read here while the menu is open and sent to the page: where the
-- player is, every blip (sprite, colour, position — GTA gives no blip's name, so only whip's own
-- carry one), the GPS line (points along the route), and the waypoint. A waypoint set on the map
-- is GTA's waypoint, so the radar's own GPS line follows it.
--
-- The keys are checked every frame, for everyone: GTA has no other way to keep its menu shut. One ControlBlocks hook holds 199 (P / Start) and 200 (Esc) off and reads them —
-- except while GTA's own frontend is up (its key bindings, or its settings menu under whip's Settings page, which
-- keeps the pad off it), whose keys are its own.

--- Is whip's pause menu up? Read by the screens list (client/inventory.lua), like the others.
PauseMenuOpen = false

local open = false

-- ============================================
-- Reading GTA's map
-- ============================================

--- Sprites the page draws itself, or that are not places: the player's own arrow (6), north (7),
--- the waypoint (8), the wanted and area circles (4, 5, 9, 10), noise and status rings.
local SKIP_SPRITE = { [4] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true,
    [10] = true, [161] = true, [163] = true, [164] = true }

--- Highest sprite id asked about. GTA's go past 900; a few spare cost two natives each.
local MAX_SPRITE = 1000

--- Display modes that never draw on the big map: 0 hidden, 5 and 9 the radar only.
local NOT_ON_MAP = { [0] = true, [5] = true, [9] = true }

--- GET_BLIP_HUD_COLOUR, by name or, on a client whose Lua lacks it, by hash.
local blipHudColour = GetBlipHudColour or function(blip)
    return Citizen.InvokeNative(0x729B5F1EFBC0AAEE, blip, Citizen.ResultAsInteger())
end

local hexCache = {}
local function hudHex(hud)
    local h = hexCache[hud]
    if h then return h end
    local r, g, b = GetHudColour(hud)
    h = ('#%02x%02x%02x'):format(r or 255, g or 255, b or 255)
    hexCache[hud] = h
    return h
end

--- The waypoint's and the GPS line's colour as the game draws them now: HUD_COLOUR_WAYPOINT, which the black HUD
--- makes whip blue (client/hud_skin.lua), as the minimap reads it (client/minimap.lua). Fresh every time, not
--- cached: the skin can change while the menu is up.
local ROUTE_HUD_COLOUR = 142
local function routeColour()
    local r, g, b = GetHudColour(ROUTE_HUD_COLOUR)
    return ('#%02x%02x%02x'):format(r or 164, g or 76, b or 242)
end

--- What a blip is attached to (GetBlipInfoIdType), for F8.
local ATTACHED = { [1] = 'a vehicle', [2] = 'a ped', [3] = 'an object', [4] = 'a fixed spot', [6] = 'a pickup', [7] = 'an area' }

--- A blip, said so it can be found: its sprite, whip's name for it, what it is attached to (a
--- player's ped by the player's name).
local function describeBlip(b, sprite)
    local kind = GetBlipInfoIdType(b)
    local on = ATTACHED[kind] or ('type ' .. tostring(kind))
    if kind == 2 then
        local ped = GetBlipInfoIdEntityIndex(b)
        if ped ~= 0 and DoesEntityExist(ped) and IsPedAPlayer(ped) then
            on = 'player ' .. tostring(GetPlayerName(NetworkGetPlayerIndexFromPed(ped)))
        end
    end
    local label = WhipBlipLabel and WhipBlipLabel(b)
    return ('sprite %d%s, attached to %s'):format(sprite, label and (' "' .. label .. '"') or '', on)
end

--- Blips GTA gave no place (NaN), each said in F8 once, by what it is.
local unplacedSaid = {}

--- Every blip on the big map: { x, y, sprite, colour, name? }.
local function readBlips()
    local list = {}
    for sprite = 0, MAX_SPRITE do
        if not SKIP_SPRITE[sprite] then
            local b = GetFirstBlipInfoId(sprite)
            while DoesBlipExist(b) do
                if not NOT_ON_MAP[GetBlipInfoIdDisplay(b)] and GetBlipAlpha(b) > 0 then
                    local c = GetBlipInfoIdCoord(b)
                    if c.x == c.x and c.y == c.y and math.abs(c.x) < math.huge and math.abs(c.y) < math.huge then
                        list[#list + 1] = {
                            x = c.x, y = c.y, sprite = sprite,
                            colour = hudHex(blipHudColour(b)),
                            name = WhipBlipLabel and WhipBlipLabel(b) or nil,
                        }
                    else
                        -- Usually one attached to something this client cannot see right now.
                        local ok, what = pcall(describeBlip, b, sprite)
                        what = ok and what or ('sprite ' .. sprite)
                        if not unplacedSaid[what] then
                            unplacedSaid[what] = true
                            print('[whip_core:pause] a blip GTA gives no position (NaN) is left off the map: ' .. what)
                        end
                    end
                end
                b = GetNextBlipInfoId(sprite)
            end
        end
    end
    return list
end

--- Points along a GPS route, `step` metres apart, from the player. GTA gives one point per question
--- (GetPosAlongGpsTypeRoute) and repeats the end once the distance passes it, which is where this
--- stops. Slot 0 is the waypoint's route, 1 a blip's (SetBlipRoute).
local ROUTE_STEP, ROUTE_MAX = 30.0, 700

--- GET_POS_ALONG_GPS_TYPE_ROUTE, under whichever name this client's Lua has: it was
--- GET_GPS_WAYPOINT_ROUTE_END until renamed, and a client may know neither — then by its hash.
local posAlongRoute = GetPosAlongGpsTypeRoute or GetGpsWaypointRouteEnd or function(fromPlayer, dist, slot)
    return Citizen.InvokeNative(0xF3162836C28F9DA5, Citizen.PointerValueVector(), fromPlayer, dist, slot,
        Citizen.ReturnResultAnyway())
end

local function readRoute(slot)
    local pts, lx, ly = {}, nil, nil
    for i = 0, ROUTE_MAX do
        local ok, p = posAlongRoute(true, i * ROUTE_STEP, slot)
        if ok == 0 then ok = false end   -- by hash, the answer is a number
        if not ok or type(p) ~= 'vector3' and type(p) ~= 'table' then break end
        -- NaN never equals itself: an answer GTA did not fill is the end, not 700 points of nothing.
        if p.x ~= p.x or p.y ~= p.y or (p.x == 0.0 and p.y == 0.0) then break end
        if lx and math.abs(p.x - lx) < 0.5 and math.abs(p.y - ly) < 0.5 then break end
        pts[#pts + 1] = { math.floor(p.x * 10) / 10, math.floor(p.y * 10) / 10 }
        lx, ly = p.x, p.y
    end
    return #pts > 1 and pts or nil
end

--- The waypoint, or FALSE when there is none, never nil: the page keeps what it has for a key the
--- message leaves out (pause-map.js setData). nil is left to mean the read failed.
local function readWaypoint()
    local wp = GetFirstBlipInfoId(8)
    if not DoesBlipExist(wp) then return false end
    local c = GetBlipInfoIdCoord(wp)
    return { x = c.x, y = c.y }
end

local function readPlayer()
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local street = GetStreetNameFromHashKey((GetStreetNameAtCoord(c.x, c.y, c.z)))
    return {
        x = c.x, y = c.y, heading = GetEntityHeading(ped),
        zone = GetLabelText(GetNameOfZone(c.x, c.y, c.z)),
        street = street,
    }
end

--- Each part read on its own: one native this client lacks must not stop the whole message. A part
--- that fails is named in F8 once and the rest still go.
local failed = {}
local function warnOnce(key, text)
    if failed[key] then return end
    failed[key] = true
    print('[whip_core:pause] ' .. text)
end

local function read(part, fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    warnOnce(part, ('could not read the %s for the map: %s'):format(part, tostring(v)))
    return nil
end

--- Every number in it one JSON can carry. GTA hands back NaN and infinities (a blip it cannot place),
--- Lua passes them on as `nan` / `inf`, and FiveM then drops the WHOLE message ("SEND_NUI_MESSAGE:
--- invalid JSON passed in frame").
local function clean(v)
    if type(v) == 'number' then return v == v and v > -math.huge and v < math.huge end
    if type(v) == 'table' then
        for _, x in pairs(v) do
            if not clean(x) then return false end
        end
    end
    return true
end

--- `v` if it is clean; else nothing, said once in F8.
local function only(part, v)
    if v == nil or clean(v) then return v end
    warnOnce(part .. ':nan', ('the %s had a number the map cannot use (NaN or infinite) and was left out'):format(part))
    return nil
end

--- The clean entries of a list, saying once if any were not.
local function cleanList(part, list)
    if type(list) ~= 'table' then return list end
    local out = {}
    for i = 1, #list do
        if clean(list[i]) then out[#out + 1] = list[i] end
    end
    if #out < #list then
        warnOnce(part .. ':nan', ('%d of the %s had a number the map cannot use (NaN or infinite) and were left out')
            :format(#list - #out, part))
    end
    return out
end

--- One message with everything that moves; `full` adds the slow parts (blips, routes).
local function push(full)
    local msg = {
        action = 'pauseData',
        player = only('player', read('player', readPlayer)),
        waypoint = only('waypoint', read('waypoint', readWaypoint)),
    }
    if full then
        msg.blips = cleanList('blips', read('blips', readBlips)) or {}
        local route = cleanList('route', read('route', readRoute, 0) or read('route', readRoute, 1))
        msg.route = (route and #route > 1) and route or false
        msg.routeColour = routeColour()
    end
    SendNUIMessage(msg)
end

--- While open: the player and waypoint four times a second, blips and the route every 2 s.
--- One feed at a time: each open is a new generation, and a feed from an older one stops (closed
--- and opened again inside 250 ms).
local feedGen = 0
local function feed(gen)
    local n = 0
    while open and gen == feedGen do
        Wait(250)
        if not open or gen ~= feedGen then break end
        n = n + 1
        push(n % 8 == 0)
    end
end

-- ============================================
-- Open and close
-- ============================================

local function closeMenu()
    if not open then return end
    open = false
    PauseMenuOpen = false
    Focus.release('pause')
    TriggerScreenblurFadeOut(200)
    SendNUIMessage({ action = 'pauseClose' })
end

local function openMenu()
    if open or not PlayerLoaded then return end
    if not IsGameInputFree() then return end   -- a screen, bar or mode has the keys: Esc is theirs
    open = true
    PauseMenuOpen = true
    Focus.take('pause', { screen = true })
    TriggerScreenblurFadeIn(200)
    SendNUIMessage({ action = 'pauseOpen' })
    feedGen = feedGen + 1
    local gen = feedGen
    CreateThread(function() feed(gen) end)   -- first, so nothing below can stop it
    push(true)
end

-- ============================================
-- The keys
-- ============================================

--- One frame: GTA's pause keys held off, and a press opens (or, from a pad, shuts) whip's menu.
local function pauseKeys()
    if IsPauseMenuActive() then return end   -- GTA's own frontend (key bindings, or under Settings): its keys are its own
    DisableControlAction(0, 199, true)       -- P, a pad's Start
    DisableControlAction(0, 200, true)       -- Esc
    local esc = IsDisabledControlJustPressed(0, 200)
    if esc or IsDisabledControlJustPressed(0, 199) then
        -- Open: Esc reaches here only with no screen holding the keyboard. Shut: only a pad's
        -- Start does — the open menu holds the keyboard, and the page answers Esc itself.
        if open then closeMenu() return end
        -- A key another block names is its exit (Esc out of /w, a camera, an editor), not this menu's.
        if ControlBlocks.heldByOthers(esc and 200 or 199, 'pauseKeys') then return end
        openMenu()
    end
end

ControlBlocks.hold('pauseKeys', {}, pauseKeys)

-- ============================================
-- The page's buttons
-- ============================================

RegisterNUICallback('pauseResume', function(_, cb)
    cb('ok')
    closeMenu()
end)

--- One of GTA's own screens in place of the pause menu. GTA's settings menu, up under the Settings page, shuts with the
--- pause menu (client/game_settings.lua); the screen opens once it has gone.
local function openGtaMenu(menu)
    closeMenu()
    local deadline = GetGameTimer() + 1000
    while IsPauseMenuActive() and GetGameTimer() < deadline do Wait(0) end
    Wait(100)
    ActivateFrontendMenu(GetHashKey(menu), false, -1)
end

--- Settings' Key Bindings tab: GTA's own key bindings screen.
RegisterNUICallback('pauseKeyBindings', function(_, cb)
    cb('ok')
    openGtaMenu('FE_MENU_VERSION_LANDING_KEYMAPPING_MENU')
end)

--- GTA's own settings menu, as Settings opened before the Settings page: the way in when the page cannot read GTA's
--- (after a game update WHIP's copy of GTA's settings page is not built for), so Graphics, Display and Audio stay
--- reachable.
RegisterNUICallback('pauseSettings', function(_, cb)
    cb('ok')
    openGtaMenu('FE_MENU_VERSION_LANDING_MENU')
end)

RegisterNUICallback('pauseLeave', function(_, cb)
    cb('ok')
    TriggerServerEvent('whip_core:server:leaveServer')
end)

--- Swap Character, after the page asked: /logout's own way back to the
--- character screen (client/main.lua), with the menu shut first.
RegisterNUICallback('pauseSwap', function(_, cb)
    cb('ok')
    closeMenu()
    if PlayerLoaded then TriggerServerEvent('whip_core:server:logout') end
end)

RegisterNUICallback('pauseWaypoint', function(data, cb)
    cb('ok')
    if type(data) ~= 'table' then return end
    if data.clear then
        SetWaypointOff()
    elseif type(data.x) == 'number' and type(data.y) == 'number' then
        SetNewWaypoint(data.x + 0.0, data.y + 0.0)
    end
    -- The route takes GTA a moment to plan; ask twice.
    SetTimeout(250, function() if open then push(true) end end)
    SetTimeout(1200, function() if open then push(true) end end)
end)

-- Logging out to character select shuts it; so does whip_core stopping.
AddEventHandler('whip_core:player:logout', closeMenu)
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() or not open then return end
    Focus.release('pause')
    TriggerScreenblurFadeOut(0)
end)
