-- ============================================
-- SYSTEMS — the editor screen's Lua half
-- ============================================
--
-- /systems (server/systems/main.lua) opens the Systems Creator's own screen: its hub (every system)
-- and its blueprint editor, one full-screen page drawn by html/js/systems/*.js, red where the
-- Director's is blue. This file is client/director.lua's sibling, with names of its own throughout
-- (a callback, an event or a key named like the Director's would answer for both):
--
--   * OPENS AND CLOSES it: the NUI focus (the 'systems' hold, client/focus.lua) and SystemsEditorOpen,
--     which makes it a screen like whip's own (client/inventory.lua's screensOpen and FocusScreenUp
--     read it, since the editor stays open while placing lets go of the focus).
--   * FORWARDS the page's requests to the server (server/systems/hub.lua), one callback each. A
--     document going up is a LATENT event first, then the callback names it by a token.
--   * PLACES a card's place in the world (the Places tab): the page hides, you aim at the floor, E puts
--     it there; the system's other places are drawn meanwhile (a line between its two ends).
--   * TESTS the system: the screen closes (you play), a strip (EditorHud) follows the card it is on.
--     The test keeps going until it is stopped: F9 brings the editor back with it still running (the
--     page asks for its report and lights its cards), F5 starts it again from fresh.
--   * CLEANS a car for the Clean Car card: the server asks the game that owns it.

SystemsEditorOpen = false

local hidden = false          -- open, but out of the way while placing
local uploadToken = 0
local uploadBps = 500000
local testing = nil           -- { name, places } while a test of ours runs

local MARK = { r = 239, g = 68, b = 68 }      -- the Systems red: a test's places, what is being placed
local OTHER = { r = 255, g = 255, b = 255 }   -- the system's other places, while placing one

local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end

local function readPlace(p)
    if type(p) ~= 'table' or not (finite(p.x) and finite(p.y) and finite(p.z)) then return nil end
    return vector3(p.x + 0.0, p.y + 0.0, p.z + 0.0)
end

--- A page's places (the Places tab's points and lines) as vectors, bounded.
local function readPlaces(d)
    local points, lines = {}, {}
    for _, p in ipairs(type(d) == 'table' and type(d.points) == 'table' and d.points or {}) do
        local v = readPlace(p)
        if v and #points < 64 then points[#points + 1] = v end
    end
    for _, l in ipairs(type(d) == 'table' and type(d.lines) == 'table' and d.lines or {}) do
        local a, b = readPlace(type(l) == 'table' and l.a), readPlace(type(l) == 'table' and l.b)
        if a and b and #lines < 32 then lines[#lines + 1] = { a, b } end
    end
    return { points = points, lines = lines }
end

-- ============================================
-- Open and close
-- ============================================

local function open()
    if SystemsEditorOpen or not PlayerLoaded or PlayerIsDead then return end
    if testing then EditorHud.hide() end
    if (IsAnyUIOpen and IsAnyUIOpen()) or (FocusScreenUp and FocusScreenUp('none')) then
        if testing then EditorHud.show(testing.hud) end
        UI.Notify('Close what is open first', 'error')
        return
    end
    SystemsEditorOpen, hidden = true, false
    Focus.take('systems', { screen = true })
    SendNUIMessage({ action = 'systemsOpen', testing = testing and testing.name or nil })
end

local function testHud()
    if not testing then return end
    testing.hud = {
        title = 'Testing',
        sub = testing.name or '',
        rows = { { label = 'Card', value = 'waiting for you…' } },
        hints = {
            { key = 'F9', text = 'Editor (it keeps running)' },
            { key = 'F5', text = 'Start it again' },
        },
    }
    EditorHud.show(testing.hud)
end

local function close()
    if not SystemsEditorOpen then return end
    SystemsEditorOpen, hidden = false, false
    if PropertyEditor and PropertyEditor.isActive() then PropertyEditor.stop('back') end
    Focus.release('systems')
    SendNUIMessage({ action = 'systemsClose' })
    TriggerServerEvent('whip_core:server:systemsClosed')
    -- A test still running: its strip again, now the game is in view.
    if testing then testHud() end
end

--- Back from placing: the page again, with the mouse.
local function show()
    if not SystemsEditorOpen or not hidden then return end
    hidden = false
    Focus.take('systems', { screen = true })
    SendNUIMessage({ action = 'systemsShow' })
end

RegisterNetEvent('whip_core:client:systemsOpen', function() open() end)

RegisterNUICallback('systemsClose', function(_, cb)
    cb('ok')
    close()
end)

-- Back from the editor to the hub: no longer editing that system (who has it open, its pulses).
RegisterNUICallback('systemsLeft', function(_, cb)
    cb('ok')
    TriggerServerEvent('whip_core:server:systemsClosed')
end)

AddEventHandler('whip_core:player:died', close)
AddEventHandler('whip_core:player:logout', function()
    close()
    if testing then
        testing = nil
        EditorHud.hide()
    end
end)
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then Focus.release('systems') end
end)

-- ============================================
-- The page's requests
-- ============================================
--
-- Each op names its arguments, in the order the server's callback takes them; nothing else is
-- forwarded. The page gets { ok = true, data } or { ok = false, why }.

local OPS = {
    list       = {},
    cards      = {},
    open       = { 'key', 'rev' },
    watch      = { 'key', 'rev' },
    history    = { 'key' },
    create     = { 'key', 'name', 'from' },
    approve    = { 'key', 'rev', 'powers' },
    activate   = { 'key', 'rev' },
    deactivate = { 'key' },
    delete     = { 'key' },
    testReport = {},
}

local function answer(cb, res, why)
    if res == nil or res == false then
        cb({ ok = false, why = why or 'No answer from the server' })
    else
        if type(res) == 'table' and res.uploadBps then uploadBps = tonumber(res.uploadBps) or uploadBps end
        cb({ ok = true, data = res })
    end
end

RegisterNUICallback('systemsCall', function(d, cb)
    local op = type(d) == 'table' and d.op or nil
    local names = type(op) == 'string' and OPS[op] or nil
    if not names then cb({ ok = false, why = 'unknown request' }) return end
    local args = type(d.args) == 'table' and d.args or {}
    local list = {}
    for i, name in ipairs(names) do list[i] = args[name] end
    answer(cb, Callback('whip_core:systems:' .. op, table.unpack(list, 1, #names)))
end)

--- Send a document up (latent), answering its token.
local function upload(doc)
    uploadToken = uploadToken + 1
    TriggerLatentServerEvent('whip_core:server:systemsDoc', uploadBps, uploadToken, doc)
    return uploadToken
end

RegisterNUICallback('systemsSave', function(d, cb)
    if type(d) ~= 'table' or type(d.doc) ~= 'table' then cb({ ok = false, why = 'nothing to save' }) return end
    local token = upload(d.doc)
    answer(cb, Callback('whip_core:systems:save', d.key, d.baseRev, token, type(d.note) == 'string' and d.note or ''))
end)

RegisterNUICallback('systemsCheck', function(d, cb)
    if type(d) ~= 'table' or type(d.doc) ~= 'table' then cb({ ok = false, why = 'nothing to check' }) return end
    local token = upload(d.doc)
    answer(cb, Callback('whip_core:systems:check', token))
end)

--- Where the player stands now (a place field's Here): no server, no wait.
RegisterNUICallback('systemsHere', function(_, cb)
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    cb({ ok = true, data = { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(ped) } })
end)

-- ============================================
-- Test
-- ============================================
--
-- The keys are made the first time someone tests, so a player who never does has no Systems lines in
-- GTA's key settings. Both do nothing unless a test of ours is running (a Director test has keys of
-- its own on the same F5 and F9: the server never lets the two run at once for one player).

local keysMade = false

-- The test's places, shown in the world:
-- every line a card waits on (a speed camera's), as a red fence between its two posts, and every point
-- (a car wash's spot) as a red ring, for as long as the test runs. Drawn each frame only while a test
-- is going and the editor is not up, and only within DRAW_RANGE of the player.
local DRAW_RANGE = 200.0
local FENCE = { 0.3, 1.1, 1.9 }   -- the fence's rails, metres above the ground
local drawing = false

local function drawTestPlaces(places)
    local me = GetEntityCoords(PlayerPedId())
    for _, l in ipairs(places.lines) do
        local a, b = l[1], l[2]
        if #(me - a) < DRAW_RANGE or #(me - b) < DRAW_RANGE then
            for _, h in ipairs(FENCE) do
                DrawLine(a.x, a.y, a.z + h, b.x, b.y, b.z + h, MARK.r, MARK.g, MARK.b, 230)
            end
            for _, p in ipairs({ a, b }) do
                DrawMarker(1, p.x, p.y, p.z - 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.35, 0.35, 2.2,
                    MARK.r, MARK.g, MARK.b, 160, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
            end
        end
    end
    for _, p in ipairs(places.points) do
        if #(me - p) < DRAW_RANGE then
            DrawMarker(25, p.x, p.y, p.z + 0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.2, 1.2, 1.2,
                MARK.r, MARK.g, MARK.b, 170, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
        end
    end
end

local function startTestDraw()
    if drawing then return end
    drawing = true
    CreateThread(function()
        while testing and testing.places do
            if not SystemsEditorOpen and (#testing.places.lines > 0 or #testing.places.points > 0) then
                drawTestPlaces(testing.places)
                Wait(0)
            else
                Wait(250)
            end
        end
        drawing = false
    end)
end

local function backToEditor()
    if not testing then return end
    open()
end

local function restartTest()
    if not testing then return end
    TriggerServerEvent('whip_core:server:systemsTestRestart')
    EditorHud.update({ rows = { { label = 'Card', value = 'starting again…', tone = 'warn' } } })
end

local function makeKeys()
    if keysMade then return end
    keysMade = true
    RegisterCommand('systems_test_back', backToEditor, false)
    RegisterCommand('systems_test_restart', restartTest, false)
    RegisterKeyMapping('systems_test_back', 'Systems: back to the editor (the test keeps running)', 'keyboard', 'F9')
    RegisterKeyMapping('systems_test_restart', 'Systems: start the test again', 'keyboard', 'F5')
end

RegisterNUICallback('systemsTest', function(d, cb)
    if type(d) ~= 'table' or type(d.doc) ~= 'table' or type(d.key) ~= 'string' then
        cb({ ok = false, why = 'nothing to test' })
        return
    end
    local token = upload(d.doc)
    local res, why = Callback('whip_core:systems:test', d.key, token)
    if type(res) ~= 'table' then cb({ ok = false, why = why or 'No answer from the server' }) return end
    cb({ ok = true, data = res })
    if res.ok == false then return end   -- it did not pass its check: the page shows why
    makeKeys()
    testing = { name = res.name or d.key, places = readPlaces(d) }
    startTestDraw()
    -- AFTER THE WAIT, ASKED AGAIN (house rule): the page may have been closed meanwhile, or a placing
    -- started. Whatever it is, out of the editor and into the game; the page keeps everything.
    if PropertyEditor and PropertyEditor.isActive() then PropertyEditor.stop('back') end
    if SystemsEditorOpen then
        SystemsEditorOpen, hidden = false, false
        Focus.release('systems')
        SendNUIMessage({ action = 'systemsClose' })
    end
    testHud()
end)

RegisterNUICallback('systemsTestStop', function(_, cb)
    local res, why = Callback('whip_core:systems:testStop')
    testing = nil
    EditorHud.hide()
    if type(res) ~= 'table' then cb({ ok = false, why = why or 'No answer from the server' }) return end
    cb({ ok = true, data = res })
end)

--- What the test ran: to the page while the editor is up (its cards light), to the strip otherwise.
RegisterNetEvent('whip_core:client:systemsTestSteps', function(steps, latest, key)
    if not testing or type(steps) ~= 'table' then return end
    if SystemsEditorOpen and not hidden then
        -- With the key: the page lights them only on that system (another one's cards share ids).
        SendNUIMessage({ action = 'systemsTestSteps', steps = steps, key = key })
    elseif type(latest) == 'table' and not SystemsEditorOpen then
        EditorHud.update({ rows = {
            { label = 'Card', value = tostring(latest.title or '?') },
            { label = 'Last', value = latest.pin and tostring(latest.pin) or tostring(latest.kind or '') },
        } })
    end
end)

RegisterNetEvent('whip_core:client:systemsTestEnded', function(e)
    if not testing then return end
    local why = type(e) == 'table' and tostring(e.reason or e.outcome or '?') or '?'
    testing = nil
    -- Not while placing a place: the strip is the placing's then (its aim and keys).
    if not (SystemsEditorOpen and hidden) then EditorHud.hide() end
    UI.Notify('The system test ended: ' .. why, 'error')
    if SystemsEditorOpen then SendNUIMessage({ action = 'systemsTestEnded', reason = why }) end
end)

RegisterNetEvent('whip_core:client:systemsTestRestarted', function()
    if not testing then return end
    if not SystemsEditorOpen then
        testHud()
        EditorHud.status('Started again', 'ok')
    else
        SendNUIMessage({ action = 'systemsTestRestarted' })
    end
end)

--- A switched-on system this editor has open went on (server/systems/hub.lua live pulses).
RegisterNetEvent('whip_core:client:systemsPulse', function(key, steps)
    if not SystemsEditorOpen or hidden or type(key) ~= 'string' or type(steps) ~= 'table' then return end
    SendNUIMessage({ action = 'systemsPulse', key = key, steps = steps })
end)

-- ============================================
-- Placing a place in the world (the Places tab)
-- ============================================

local REACH = 40.0

RegisterNUICallback('systemsPlace', function(d, cb)
    cb('ok')
    if not SystemsEditorOpen or hidden or type(d) ~= 'table' or type(d.node) ~= 'string' or type(d.key) ~= 'string' then return end
    if not PropertyEditor then return end
    -- The system's other places, drawn while aiming: points, and each line between its two ends (the
    -- other end of the line being placed among them).
    local placesNow = readPlaces(d)
    local points, lines = placesNow.points, placesNow.lines
    local partner = readPlace(d.partner)   -- the line's other end, when placing one end of a line
    hidden = true
    Focus.release('systems')   -- the editor is still open (SystemsEditorOpen): FocusScreenUp says so
    SendNUIMessage({ action = 'systemsHide' })

    local x, y, z, valid = 0.0, 0.0, 0.0, false
    local label = type(d.label) == 'string' and d.label ~= '' and d.label or 'a place'
    local started = PropertyEditor.start({
        name = 'Systems: place',
        hud = {
            title = 'Place ' .. label,
            sub = partner and 'a line: the other end is shown' or 'aim at the ground',
            rows = { { label = 'Aim', value = 'at the floor' } },
            hints = {
                { key = 'E', text = 'Here' },
                { key = 'C', text = 'Cancel' },
                { key = 'Esc', text = 'Back' },
            },
        },
        -- Weapon scroll, getting in, shooting, aiming, the wheel, cover, melee: held off for the mode by the
        -- editor's control block. And C (26), the cancel, so it does not swing the camera round as well; read
        -- with the disabled reader.
        block = { controls = { 14, 15, 16, 17, 23, 24, 25, 26, 37, 44, 140 } },
        onFrame = function()
            local cam = GetFinalRenderedCamCoord()
            local fx, fy, fz = InteractGetCameraForward()
            local ray = StartShapeTestRay(cam.x, cam.y, cam.z, cam.x + fx * REACH, cam.y + fy * REACH, cam.z + fz * REACH,
                1 + 16, PlayerPedId(), 0)
            local _, hit, coords = GetShapeTestResult(ray)
            valid = hit == 1
            if valid then x, y, z = coords.x, coords.y, coords.z end
            for _, p in ipairs(points) do
                DrawMarker(28, p.x, p.y, p.z + 0.15, 0, 0, 0, 0, 0, 0, 0.25, 0.25, 0.25, OTHER.r, OTHER.g, OTHER.b, 140,
                    false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
            end
            for _, l in ipairs(lines) do
                DrawLine(l[1].x, l[1].y, l[1].z + 0.3, l[2].x, l[2].y, l[2].z + 0.3, OTHER.r, OTHER.g, OTHER.b, 200)
            end
            if partner then
                DrawMarker(28, partner.x, partner.y, partner.z + 0.15, 0, 0, 0, 0, 0, 0, 0.3, 0.3, 0.3, MARK.r, MARK.g, MARK.b, 200,
                    false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                if valid then DrawLine(partner.x, partner.y, partner.z + 0.3, x, y, z + 0.3, MARK.r, MARK.g, MARK.b, 255) end
            end
            if valid then
                DrawMarker(25, x, y, z + 0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8, MARK.r, MARK.g, MARK.b, 200,
                    false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
            end
            EditorHud.update({ rows = {
                { label = 'Aim', value = valid and ('%.1f, %.1f'):format(x, y) or 'nothing in reach', tone = valid and 'ok' or 'warn' },
                partner and valid and { label = 'Line', value = ('%.1f m long'):format(#(vector3(x, y, z) - partner)) } or nil,
            } })
            if valid and IsControlJustPressed(0, 38) then
                SendNUIMessage({ action = 'systemsPlaced', node = d.node, key = d.key,
                                 coords = { x = x, y = y, z = z, heading = GetEntityHeading(PlayerPedId()) } })
                return 'exit'
            end
            if IsDisabledControlJustPressed(0, 26) then return 'exit' end
        end,
        onExit = function(reason)
            if reason == 'died' then close()
            elseif reason ~= 'stopped' then show() end
        end,
    })
    if not started then show() end
end)

-- ============================================
-- Clean Car (server/systems/cards_server.lua): the game that owns the car washes it
-- ============================================

RegisterNetEvent('whip_core:client:systemsCleanCar', function(netId)
    if type(netId) ~= 'number' or not NetworkDoesNetworkIdExist(netId) then return end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh == 0 or not DoesEntityExist(veh) or not IsEntityAVehicle(veh) or not NetworkHasControlOfEntity(veh) then return end
    SetVehicleDirtLevel(veh, 0.0)
    WashDecalsFromVehicle(veh, 1.0)
end)
