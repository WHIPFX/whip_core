-- Native HUD hiding, minimap control, health regen disable, HUD visibility. Stat values: client/stats.lua.

local isInVehicle = false

-- The minimap on foot and in a vehicle: the player's own choice (pause menu, Settings → Server → Minimap) unless the
-- server decides (Config.MapOptions.onFoot / .inVehicle: 'on', 'off' or 'player').

--- The server's answer for one of them, or nil while each player chooses.
local function serverShows(field)
    return function()
        local m = Config.MapOptions and Config.MapOptions[field]
        if m == 'on' then return true elseif m == 'off' then return false end
        return nil
    end
end

PlayerPrefs.define({
    key = 'map.onFoot', group = 'Minimap', type = 'toggle', label = 'Show on foot',
    help = 'The minimap on foot.',
    default = false, forced = serverShows('onFoot'),
})

PlayerPrefs.define({
    key = 'map.inVehicle', group = 'Minimap', type = 'toggle', label = 'Show in a vehicle',
    help = 'The minimap in a vehicle.',
    default = true, forced = serverShows('inVehicle'),
})

local function showMinimapOnFoot()
    return PlayerPrefs.get('map.onFoot') == true
end

local function showMinimapInVehicle()
    return PlayerPrefs.get('map.inVehicle') ~= false
end

--- The minimap wanted, in a vehicle or on foot.
local function minimapFor(inVehicle)
    if inVehicle then return showMinimapInVehicle() end
    return showMinimapOnFoot()
end

-- Hiding GTA's own HUD: HideHudComponentThisFrame lasts one frame, so components are moved off screen
-- with SetHudComponentPosition instead. Positions reset on a resolution change (no event), so they are
-- re-applied every second; a component that ignores a position goes in HUD_PER_FRAME.

--- How far off screen a hidden component is pushed (units undocumented; -2.0 is off screen either way).
local HUD_OFFSCREEN = -2.0

--- Components pushed off screen once and left there. Not the car names (6-9): the move does not hold
--- for them, so CAR_NAMES hides them every frame.
local HUD_HIDDEN = {
    1,  -- WANTED_STARS
    2,  -- WEAPON_ICON
    3,  -- CASH
    4,  -- MP_CASH
    14, -- RETICLE

    -- The weapon wheel: flag 48 blocks switching but not drawing, so it is moved off screen. 20 is its stats panel.
    19, -- WEAPON_WHEEL
    20, -- WEAPON_WHEEL_STATS
}

--- Components that refuse to stay moved and need the per-frame call. The thread below exists only if this is non-empty.
local HUD_PER_FRAME = {}

--- GTA's car names (vehicle name and class, area, street), hidden with the per-frame call while a character
--- is loaded. Runs on the ControlBlocks loop (client/pause.lua), held by the radar loop below and let go at logout.
local CAR_NAMES = {
    6,  -- VEHICLE_NAME
    7,  -- AREA_NAME
    8,  -- VEHICLE_CLASS
    9,  -- STREET_NAME
}

local function hideCarNames()
    for i = 1, #CAR_NAMES do HideHudComponentThisFrame(CAR_NAMES[i]) end
end

--- A character is loaded, as the radar loop last saw it.
local carNamesArmed = false

local function armCarNames(armed)
    if armed == carNamesArmed then return end
    carNamesArmed = armed
    if armed then ControlBlocks.hold('carNames', {}, hideCarNames) else ControlBlocks.release('carNames') end
end

--- Push every HUD_HIDDEN component out of view. Safe to call repeatedly.
local function ApplyHudOffsets()
    for i = 1, #HUD_HIDDEN do
        SetHudComponentPosition(HUD_HIDDEN[i], HUD_OFFSCREEN, HUD_OFFSCREEN)
    end
end

--- Re-apply every second while a character is loaded (GTA restores its HUD during a death at its own timing).
CreateThread(function()
    local lastW, lastH = 0, 0

    while true do
        Wait(1000)

        local w, h = GetActiveScreenResolution()
        if PlayerLoaded or w ~= lastW or h ~= lastH then
            lastW, lastH = w, h
            ApplyHudOffsets()
        end
    end
end)

-- Applied immediately too, so the native HUD is not drawn during the watcher's first sleep.
ApplyHudOffsets()

-- And at once after a death; the watcher above is the backstop.
AddEventHandler('whip_core:player:revived', ApplyHudOffsets)

--- The HUD_PER_FRAME leftovers (no thread when the list is empty).
if #HUD_PER_FRAME > 0 then
    CreateThread(function()
        while true do
            if PlayerLoaded then
                for i = 1, #HUD_PER_FRAME do
                    HideHudComponentThisFrame(HUD_PER_FRAME[i])
                end
                Wait(0)
            else
                Wait(500)
            end
        end
    end)
end

-- Minimap repositioning + health/armour bar hiding

--- The minimap scaleform, held so the radar thread can reassert on it.
local minimapScaleform = nil

--- Hide the health and armour bars around the minimap (param 3 is the "no bars" mode). The game
--- re-creates the scaleform at times (model swap, death), so the radar loop reasserts it.
local function HideMinimapHealthArmour()
    if not minimapScaleform then return end

    BeginScaleformMovieMethod(minimapScaleform, "SETUP_HEALTH_ARMOUR")
    ScaleformMovieMethodAddParamInt(3)
    EndScaleformMovieMethod()
end

--- Swap the radar mask for whip's own. radarmasksm is a greyscale image: brightness is the minimap's
--- opacity and its edge is the falloff. AddReplaceTexture points at our dictionary; a missing or slow
--- dictionary leaves the vanilla mask.
---@return boolean applied
local function ApplyMinimapMask()
    local shape = Config.MinimapMask
    if not shape then return false end

    local dict = 'whipmask_' .. tostring(shape)

    -- 2 s, for a cold start with a busy streamer.
    if not LoadTextureDict(dict, 2000) then
        print(('[whip_core:hud] minimap mask "%s" did not stream — keeping the game\'s own mask. '
            .. 'Expected stream/%s.ytd'):format(tostring(shape), dict))
        return false
    end

    -- The shape changed while the dictionary loaded: the newer swap has it; this older one must not land on top.
    if Config.MinimapMask ~= shape then return false end

    -- Source and destination textures share the name 'radarmasksm'.
    AddReplaceTexture('platform:/textures/graphics', 'radarmasksm', dict, 'radarmasksm')
    return true
end

--- The three component rects, tuned by eye with /radar. They move together (map, mask and blur are one
--- object). Order: posX, posY, sizeX, sizeY, normalised, anchored Left/Bottom; Y lifts the radar clear of the status HUD.
local radarRects = {
    -- The minimap rect also places the scaleform overlay (compass N, waypoint arrow): resize the map with minimap_blur instead.
    minimap      = {  0.0000, -0.0505, 0.1795, 0.2000 },
    -- The mask rect is the GPS route layer, on its own mapping: hence several times the other two.
    minimap_mask = {  0.0295,  0.0780, 0.4355, 0.5160 },
    -- Never zero the blur: the whole minimap becomes invisible.
    minimap_blur = {  0.0040, -0.0670, 0.1761, 0.1708 },
}

--- Push the table at the game. Safe to call repeatedly from anywhere. The rebuild runs in its own
--- thread: SetMinimapComponentPosition takes effect at the next radar rebuild, which toggling bigmap
--- forces with a real frame in between. The toggle resets the scaleform (bars return), so the hide is
--- re-asserted after it.
--- Clip type to assert after every rebuild (tuned through /radardebug). Asserting 0 differs from the
--- tuner's -1 (leave alone): the bigmap toggle and replaced mask disturb scaleform state nothing else restores.
local MINIMAP_CLIP_TYPE = 0

local function ApplyRadarRects()
    for name, r in pairs(radarRects) do
        SetMinimapComponentPosition(name, 'L', 'B', r[1], r[2], r[3], r[4])
    end

    CreateThread(function()
        SetRadarBigmapEnabled(true, false)
        -- A full frame: Wait(0) is not reliably enough for the radar to rebuild.
        Wait(50)
        SetRadarBigmapEnabled(false, false)
        Wait(0)
        -- Both after the toggle: the rebuild restores scaleform state.
        SetMinimapClipType(MINIMAP_CLIP_TYPE)
        HideMinimapHealthArmour()
    end)
end

CreateThread(function()
    minimapScaleform = RequestScaleformMovie("minimap")

    -- Before the rects, so the one rebuild picks up the swap.
    ApplyMinimapMask()
    -- Carries the bigmap rebuild and the health/armour hide that follows it.
    ApplyRadarRects()
end)

-- After a death, re-assert the bars and the clip (no bigmap toggle: its flash would show).
AddEventHandler('whip_core:player:revived', function()
    SetMinimapClipType(MINIMAP_CLIP_TYPE)
    HideMinimapHealthArmour()
end)

-- The mask setting changed: swap it, then rebuild as at start. A thread, because the swap waits for its dictionary.
Settings.onChange('MinimapMask', function(shape)
    CreateThread(function()
        if shape then
            ApplyMinimapMask()
        else
            RemoveReplaceTexture('platform:/textures/graphics', 'radarmasksm')
        end
        ApplyRadarRects()
    end)
end)

-- /radar: live tuning for the three rects. Nudge, look, then paste the printed line back into radarRects.
-- Client-side and ungated: it moves only this player's radar and does not survive a reconnect.

local RADAR_PARTS = { minimap = 'minimap', mask = 'minimap_mask', blur = 'minimap_blur' }

--- Which component the nudges act on. 'all' moves the three together. `minimap` and `minimap_blur` both
--- resize the map, but only `minimap` moves the scaleform overlay (compass N). `minimap_mask` places the GPS route line.
local radarFocus = 'all'

--- Which rects a nudge touches, given the focus.
local function FocusedRects()
    if radarFocus == 'all' then return radarRects end
    return { [radarFocus] = radarRects[radarFocus] }
end

--- Print the table in a form that pastes back into radarRects.
local function PrintRadarRects()
    print(('[whip_core:radar] focus: %s'):format(radarFocus))
    print('[whip_core:radar] radarRects = {')
    for _, name in ipairs({ 'minimap', 'minimap_mask', 'minimap_blur' }) do
        local r = radarRects[name]
        print(('    %-13s = { %7.4f, %7.4f, %7.4f, %7.4f },'):format(name, r[1], r[2], r[3], r[4]))
    end
    print('}')
end

-- Seams for the radar tuner (client/radar_debug.lua): shipped values, mask swap, health-bar hide. Globals, not exports.

--- The rect whip ships for a component, or nil for one it does not manage.
---@param key string
---@return table|nil
function RadarGetShippedRect(key)
    return radarRects[key]
end

--- The clip type whip asserts after each rebuild.
---@return integer
function RadarGetShippedClipType()
    return MINIMAP_CLIP_TYPE
end

--- Re-run the mask swap. Reads Config.MinimapMask, so set that first.
function ApplyMinimapMaskPublic()
    return ApplyMinimapMask()
end

--- Global alias: the tuner reasserts the bar hide after its own rebuilds.
function HideMinimapHealthArmourPublic()
    return HideMinimapHealthArmour()
end

--- Rebuild the radar with whip's rects, so it picks up a texture swap (client/hud_skin.lua's dark map).
function RadarRebuild()
    return ApplyRadarRects()
end

RegisterCommand('radar', function(_, args)
    local part = args[1] and args[1]:lower()

    if not part or part == 'print' then
        PrintRadarRects()
        return
    end

    -- `only` aims every later nudge at one component.
    if part == 'only' then
        local want = args[2] and args[2]:lower()
        if want == 'all' then
            radarFocus = 'all'
        elseif RADAR_PARTS[want] then
            radarFocus = RADAR_PARTS[want]
        else
            print('[whip_core:radar] usage: /radar only <minimap|mask|blur|all>')
            return
        end
        print(('[whip_core:radar] focus is now: %s'):format(radarFocus))
        return
    end

    -- `all` scales every rect at once.
    if part == 'scale' then
        local sx = tonumber(args[2])
        local sy = tonumber(args[3]) or sx
        if not sx then
            print('[whip_core:radar] usage: /radar scale <x> [y]   e.g. /radar scale 0.9')
            return
        end
        for _, r in pairs(FocusedRects()) do
            r[3] = r[3] * sx
            r[4] = r[4] * sy
        end
        ApplyRadarRects()
        PrintRadarRects()
        return
    end

    -- `probe` halves each rect in turn to see what it does. Set a waypoint first (minimap_mask owns the GPS line). Always restores.
    if part == 'probe' then
        CreateThread(function()
            local order = { 'minimap', 'minimap_mask', 'minimap_blur' }
            for _, name in ipairs(order) do
                local r = radarRects[name]
                local sx, sy = r[3], r[4]

                print(('[whip_core:radar] PROBE %s — halving its size for 3s, watch the radar')
                    :format(name))
                r[3], r[4] = sx * 0.5, sy * 0.5
                ApplyRadarRects()
                Wait(3000)

                r[3], r[4] = sx, sy
                ApplyRadarRects()
                Wait(1200)
            end
            print('[whip_core:radar] PROBE done. Whichever step visibly shrank the map is the')
            print('[whip_core:radar] component that owns the visible edge — tune that one.')
            print('[whip_core:radar] A step that moved nothing is UNTESTED, not inert: set a')
            print('[whip_core:radar] waypoint and re-run, or minimap_mask (the GPS line) is missed.')
        end)
        return
    end

    -- `move` shifts every rect together.
    if part == 'move' then
        local dx = tonumber(args[2]) or 0
        local dy = tonumber(args[3]) or 0
        for _, r in pairs(FocusedRects()) do
            r[1] = r[1] + dx
            r[2] = r[2] + dy
        end
        ApplyRadarRects()
        PrintRadarRects()
        return
    end

    -- Field 1 is which number in the rect (1 posX, 2 posY, 3 sizeX, 4 sizeY), field 2 the direction.
    local NUDGE = {
        left     = { 1, -1 },  right  = { 1,  1 },
        down     = { 2, -1 },  up     = { 2,  1 },
        narrower = { 3, -1 },  wider  = { 3,  1 },
        shorter  = { 4, -1 },  taller = { 4,  1 },
    }

    local n = NUDGE[part]
    if n then
        -- 0.002 is about two pixels at 1080p. Override for a coarse pass: /radar up 0.02
        local step = tonumber(args[2]) or 0.002
        local idx, sign = n[1], n[2]
        for _, r in pairs(FocusedRects()) do
            r[idx] = r[idx] + step * sign
        end
        ApplyRadarRects()
        PrintRadarRects()
        return
    end

    local name = RADAR_PARTS[part]
    if not name then
        print('[whip_core:radar] usage — every form re-applies live and prints the table:')
        print('  /radar                          print current values + focus')
        print('  focus (nudges act on this; minimap is the only one that moves the N):')
        print('    /radar only <minimap|mask|blur|all>')
        print('  nudge (step defaults to 0.002, pass your own for a coarse pass):')
        print('    /radar up | down | left | right        [step]')
        print('    /radar wider | narrower                [step]')
        print('    /radar taller | shorter                [step]')
        print('  diagnose:')
        print('    /radar probe                  halve each component in turn, 3s each')
        print('  bulk:')
        print('    /radar scale <x> [y]          resize all three (0.9 = 10% smaller)')
        print('    /radar move <dx> <dy>         shift all three (+x right, +y up)')
        print('  exact:')
        print('    /radar <minimap|mask|blur> <posX> <posY> <sizeX> <sizeY>')
        return
    end

    local r = radarRects[name]
    for i = 1, 4 do
        local v = tonumber(args[i + 1])
        if v then r[i] = v end
    end
    ApplyRadarRects()
    PrintRadarRects()
end, false)

-- HUD visibility, pushed rather than polled:
--   IsAnyScreenOpen()  client/inventory.lua fires whip_core:ui:stateChanged on every transition.
--   PlayerIsDead       client/death.lua calls the function below after each write.
--   frontendUp         GTA's own pause menu, which no event announces: the radar loop below looks five times a second.

--- What the panel was last told, so an unchanged signal sends nothing.
local hudLastHidden = false

--- GTA's own pause menu is up (its frontend: the map, its settings pages). The game draws it under this page, so the
--- gauges, the minimap and the vehicle dial (which follow the status HUD's fade) would sit on top of it.
local frontendUp = false

--- True between this file's own playerLoaded and playerLogout handlers. Not PlayerLoaded alone: handlers for
--- one event run in no set order, so another file's logout handler could refresh the HUD back over character select.
local hudUp = false

--- Re-decide whether the status HUD is on screen and tell the page if it changed. Idempotent, safe to call
--- from anywhere. A global, not an export: satellites declare themselves through SetScreenOpen.
function WhipRefreshHudVisibility()
    -- Nothing to hide before load; the playerLoaded handler at the bottom does the first paint.
    if not PlayerLoaded or not hudUp then return end

    -- A screen, not merely "busy": a progress bar leaves the HUD up. Asked as the HUD (true): a screen opened
    -- with keepHud (the phone) leaves it up too. GTA's pause menu hides it as one of whip's screens does.
    local shouldHide = (IsAnyScreenOpen and IsAnyScreenOpen(true)) or PlayerIsDead or frontendUp
    if shouldHide == hudLastHidden then return end

    hudLastHidden = shouldHide
    SendNUIMessage({ action = shouldHide and 'hideStatusHud' or 'showStatusHud' })
end

--- The UI half: fires on every open and close (client/inventory.lua). The argument is ignored.
AddEventHandler('whip_core:ui:stateChanged', function()
    WhipRefreshHudVisibility()
end)

-- SetScreenArea: a satellite whose UI sits in the HUD's corner says where, and the vehicle dial (and the pad's
-- buttons on it) slides up or left, or fades if neither fits (html/js/vehicle-dial.js).
--
--     exports.whip_core:SetScreenArea({ left = 0.78, top = 0.46, right = 0.98, bottom = 1.0 }, 'phone')   -- fractions of the screen
--     exports.whip_core:SetScreenArea(nil, 'phone')                                                        -- gone
--
-- Send where it will be once still, when that changes. Held under '<resource>:<key>' and released when that
-- resource stops. An area hides nothing and takes no keys (SetScreenOpen does that).

--- ['<resource>:<key>'] = { left, top, right, bottom }
local areaStore = {}

local function sendUIAreas()
    local list = {}
    for _, a in pairs(areaStore) do
        list[#list + 1] = { left = a.left, top = a.top, right = a.right, bottom = a.bottom }
    end
    SendNUIMessage({ action = 'uiAreas', areas = list })
end

local uiAreas = Registry.new('uiArea', {
    label    = 'screen area',
    store    = areaStore,
    scoped   = true,   -- '<resource>:<key>'
    validate = function(_, a)
        if type(a) ~= 'table' then return false, 'an area is { left, top, right, bottom }' end
        for _, k in ipairs({ 'left', 'top', 'right', 'bottom' }) do
            local v = a[k]
            if type(v) ~= 'number' or v ~= v or v < 0 or v > 1 then
                return false, ('area.%s must be a number from 0 to 1 (a fraction of the screen)'):format(k)
            end
        end
        if a.right <= a.left or a.bottom <= a.top then return false, 'an area needs right > left and bottom > top' end
        return true
    end,
    onAdd    = sendUIAreas,
    onRemove = sendUIAreas,
})

exports('SetScreenArea', function(area, key)
    if not GetInvokingResource() then return false end
    local owner, id = Registry.caller(), tostring(key or 'default')
    if area == nil or area == false then
        uiAreas:remove(owner, id)
        return true
    end
    if type(area) ~= 'table' then return false, 'an area is { left, top, right, bottom }' end
    return uiAreas:add(owner, id, {
        left = tonumber(area.left), top = tonumber(area.top), right = tonumber(area.right), bottom = tonumber(area.bottom),
    })
end)

-- Vehicle enter/exit: minimap toggle

--- The capsule's line is a / command: its suggestion list floats over the radar's corner, so the radar
--- steps aside (html/js/composer.js says when, 'composerCommandList').
local commandListUp = false

--- What the radar state should be right now. Open screens hide it, as they hide the status HUD.
local function radarShouldShow()
    -- The tuner forces it on; checked before IsAnyScreenOpen, which its NUI focus would trip.
    if RadarDebugOpen then return true end
    -- Down: the death screen has the status HUD (and the minimap with it) hidden, so nothing feeds it meanwhile
    if PlayerIsDead then return false end
    -- a bar keeps the radar; so does a satellite screen opened with keepHud (the phone), as it keeps the status HUD
    if IsAnyScreenOpen and IsAnyScreenOpen(true) then return false end
    -- Only while the composer is still open: a page that never said "closed" cannot keep it hidden.
    if commandListUp and ComposerIsOpen ~= nil and ComposerIsOpen() then return false end
    return minimapFor(isInVehicle)
end

--- GTA's radar is shown only to the tuner (/radardebug). Everyone else sees whip's own minimap
--- (client/minimap.lua, html/js/minimap.js) when the radar would show, but not under GTA's pause menu.
---@param want boolean  radarShouldShow's answer
local function radarFor(want)
    return want and RadarDebugOpen == true
end

local function applyRadar(want)
    DisplayRadar(radarFor(want))
    MinimapShow(want and not RadarDebugOpen and not IsPauseMenuActive())
end

-- At once rather than on the loop's next pass (up to 200 ms), as the list appears when / is typed.
RegisterNUICallback('composerCommandList', function(data, cb)
    commandListUp = type(data) == 'table' and data.open == true
    if PlayerLoaded then applyRadar(radarShouldShow()) end
    cb('ok')
end)

--- Passes between unconditional health/armour re-asserts: 25 x 200ms = 5 s. Tied to the Wait(200) in the loop.
local HEALTH_ARMOUR_REASSERT_PASSES = 25

CreateThread(function()
    while not PlayerLoaded do Wait(500) end
    applyRadar(minimapFor(isInVehicle))

    local shown = minimapFor(isInVehicle)

    -- What the health/armour re-assert watches (see the bottom of the loop).
    local lastModel = 0
    local passesSinceAssert = HEALTH_ARMOUR_REASSERT_PASSES

    while true do
        Wait(200)
        if not PlayerLoaded then goto skip end

        local cost = WhipCost.start()
        local ped = PlayerPedId()
        isInVehicle = IsPedInAnyVehicle(ped, false)
        -- GTA's car, area and street names: hidden in a vehicle and on foot alike (CAR_NAMES above)
        armCarNames(true)

        -- GTA's radar only on change or when the game disagrees (death, a satellite's DisplayRadar). IsRadarHidden
        -- is a BOOL native (1 or false: never `== true`). whip's minimap every pass: MinimapShow is change-gated.
        local want = radarShouldShow()
        local shownChanged = (want ~= shown)
        local gameShows = not IsRadarHidden()
        if shownChanged or gameShows ~= radarFor(want) then
            shown = want
            DisplayRadar(radarFor(want))
        end
        MinimapShow(want and not RadarDebugOpen and not IsPauseMenuActive())

        -- GTA's pause menu came up or went (a BOOL native, as above): the HUD goes with it, or comes back.
        local frontend = IsPauseMenuActive() and true or false
        if frontend ~= frontendUp then
            frontendUp = frontend
            WhipRefreshHudVisibility()
        end

        -- The health/armour hide is reasserted whether or not the radar is up. Scaleform calls are not cheap,
        -- so only on a model swap, on the radar coming back, and on a 5 s heartbeat.
        local model = GetEntityModel(ped)
        passesSinceAssert = passesSinceAssert + 1

        if model ~= lastModel
            or shownChanged
            or passesSinceAssert >= HEALTH_ARMOUR_REASSERT_PASSES then
            lastModel = model
            passesSinceAssert = 0
            HideMinimapHealthArmour()
        end

        WhipCost.stop('radar: shown or hidden, health bars (5 a second)', cost)

        ::skip::
    end
end)

-- Player load/logout: health regen disable + HUD init

RegisterNetEvent('whip_core:client:playerLoaded', function()
    -- Disable GTA's native health regen to 50 HP
    SetPlayerHealthRechargeMultiplier(PlayerId(), 0.0)
    SetPlayerHealthRechargeLimit(PlayerId(), 0.0)

    -- Show HUD
    local ped = PlayerPedId()
    local inVehicle = IsPedInAnyVehicle(ped, false)
    applyRadar(minimapFor(inVehicle))
    isInVehicle = inVehicle

    -- The first paint, and the seed for the change gate (WhipRefreshHudVisibility bails while PlayerLoaded is false).
    SendNUIMessage({ action = 'showStatusHud' })
    hudLastHidden = false
    hudUp = true
end)

RegisterNetEvent('whip_core:client:playerLogout', function()
    hudUp = false
    SendNUIMessage({ action = 'hideStatusHud' })
    hudLastHidden = true
    applyRadar(false)
    armCarNames(false)   -- the radar loop skips while logged out, so it would not let go
end)

-- Restore minimap on resource stop
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    DisplayRadar(true)
end)
