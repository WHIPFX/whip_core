-- ============================================
-- /whip SECTION — Config, and each satellite's settings page (client wiring)
-- ============================================
--
-- The Lua half of html/js/wp/config.js. Fetches every settings page from the server
-- (server/settings.lua) when a settings section opens, carries an Apply to the server, and redraws
-- when any admin saves (whip_core:client:settingsSaved reaches everyone, us included). The server
-- decides who may see and change settings; this file only asks.
--
-- ONE SECTION PER PAGE: 'config' is whip_core's, 'settings:<resource>' a satellite's. They are the
-- same code (forPage); tools/whip_panel.lua makes a satellite's when the panel opens.

local entered = {}   -- [sectionId] = true while that section is on screen

--- GTA's switch scenes (client/arrival_list.lua), for the arrival scene lists' Add scenes on whip_core's page: what
--- each is and what it needs. Made once.
local catalogue = nil
local function arrivalCatalogue()
    if catalogue then return catalogue end
    catalogue = {}
    for _, e in ipairs(ArrivalSceneList or {}) do
        catalogue[#catalogue + 1] = { dict = e.dict, clip = e.clip, cam = e.cam, label = e.label, who = e.who,
                                      car = e.car == true or nil, others = e.others == true or nil }
    end
    return catalogue
end

local function fetch(sectionId)
    CreateThread(function()
        local ok, data, why = pcall(Callback, 'whip_core:settings:panel')
        if not entered[sectionId] then return end
        if ok and type(data) == 'table' then
            if sectionId == 'config' then data.arrivalCatalogue = arrivalCatalogue() end
            WhipPanelData(sectionId, 'all', data)
        else
            WhipPanelData(sectionId, 'error', { why = ok and why or 'The settings could not be read' })
        end
    end)
end

--- A settings section's enter and leave.
---@param sectionId string
local function forPage(sectionId)
    return {
        enter = function()
            entered[sectionId] = true
            fetch(sectionId)
        end,
        leave = function()
            entered[sectionId] = nil
        end,
    }
end

PanelSections['config'] = forPage('config')
PanelSections['config'].forPage = forPage

RegisterNetEvent('whip_core:client:settingsSaved', function()
    for sectionId in pairs(entered) do fetch(sectionId) end
end)

-- "Use where I stand": the admin's own feet and facing, for a position setting. Only a reading;
-- the panel checks it and it goes through Apply like anything typed.
RegisterNUICallback('cfgHere', function(_, cb)
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    cb({ x = pos.x, y = pos.y, z = pos.z, w = GetEntityHeading(ped) })
end)

-- "Use my camera": where the camera the admin is looking through is, which way it turns (pitch,
-- roll, yaw) and its zoom, for a shot setting (the character screen's, the landing page's).
RegisterNUICallback('cfgCamera', function(_, cb)
    local c, r = GetFinalRenderedCamCoord(), GetFinalRenderedCamRot(2)
    cb({
        pos = { x = c.x, y = c.y, z = c.z },
        rot = { x = r.x, y = r.y, z = r.z },
        fov = GetFinalRenderedCamFov(),
    })
end)

-- ---- "Place camera" ----
--
-- A shot's camera flown into place, as noclip flies: the panel steps aside (WhipPanelSuspend), a free camera
-- starts AT the shot as the panel has it (unsaved edits too), and Enter takes its place, turn and zoom back to
-- the panel as edits waiting for Apply ('cameraPlaced', html/js/wp/config.js). Esc leaves the shot as it was.
-- Nothing is saved here: the panel checks the three and Apply sends them, like anything typed.
--
-- The player does not move (pedFollows = false): they are hidden and held where they stand, and land back
-- there. The keys are this mode's while it lasts (a block naming Enter and Esc, so whip's pause menu leaves
-- Esc alone), and the box at the top right (EditorHud) says which do what, a controller's when one is in use.

local placing = nil   -- { section, path } while a shot is being flown

local PLACE_TAKE   = { 191, 201 }        -- Enter (a pad's A)
-- Esc, Backspace, a pad's B. NOT 177 (INPUT_CELLPHONE_CANCEL): it is also the right mouse button, so holding it to
-- look round would end the flight (the furnisher's exit note records the same trap).
local PLACE_CANCEL = { 200, 202 }
local PAD_ZOOM_IN, PAD_ZOOM_OUT = 172, 173   -- D-pad up and down: a controller has no wheel
local PAD_ZOOM_RATE = 30.0                   -- degrees a second

local function anyJustPressed(list)
    for _, c in ipairs(list) do
        if IsDisabledControlJustPressed(0, c) then return true end
    end
    return false
end

-- The house card's keys: a keyboard's caps, or a pad's pictures when one is in hand (the card swaps them itself).
-- The flying ones in its small Camera group, as the door editor's.
local PLACE_HINTS = {
    { key = 'Enter',        pad = 'a',                        text = 'Use this shot' },
    { key = 'Esc',          pad = 'b',                        text = 'Cancel' },
    { key = 'WASD',         pad = 'ls',                       text = 'Move',      group = 'fly' },
    { key = 'Mouse',        pad = 'rs',                       text = 'Look',      group = 'fly' },
    { key = 'Space / Ctrl', pad = { 'rt', 'lt' },             text = 'Up / down', group = 'fly' },
    { key = 'Wheel',        pad = { 'dpad_up', 'dpad_down' }, text = 'Zoom',      group = 'fly' },
    { key = 'Shift',        pad = 'l3',                       text = 'Faster',    group = 'fly' },
}

local function placeRows()
    local p, r = FreeCam.getCoord(), FreeCam.getRot()
    local f = FreeCam.getFov()
    return {
        { label = 'Place', value = ('%.2f, %.2f, %.2f'):format(p.x, p.y, p.z) },
        { label = 'Turn', value = ('%.1f, %.1f'):format(r.x, r.z) },
        { label = 'Zoom', value = ('%.1f°'):format(f) },
    }
end

--- End the flight: the camera back on the player, the panel back, and with `take` the shot sent to it.
---@param take boolean
local function finishPlacing(take)
    local p = placing
    if not p then return end
    placing = nil
    ControlBlocks.release('cfgPlaceCamera')
    local pos, rot = FreeCam.getCoord(), FreeCam.getRot()
    local fov = FreeCam.getFov()
    EditorHud.hide()
    FreeCam.stop({ movePed = false })   -- waits for the ground under the player: in a thread
    WhipPanelResume()
    if take then
        WhipPanelData(p.section, 'cameraPlaced', {
            path = p.path,
            pos = { x = pos.x, y = pos.y, z = pos.z },
            rot = { x = rot.x, y = 0.0, z = rot.z },
            fov = fov,
        })
        WhipPanelResult('Shot placed: Apply to keep it.', 'ok')
    end
end

--- One frame of the flight, inside the control loop: the keys, the controller's zoom, the box.
local lastRows = 0
local function placeFrame()
    if not placing then return end
    -- The panel closed meanwhile (its resource restarting): nothing to take the shot to.
    if not WhipPanelIsOpen() or not FreeCam.isActive() then
        CreateThread(function() finishPlacing(false) end)
        return
    end
    FreeCam.setPad(WhipPadActive)
    if WhipPadActive then
        local _, want = FreeCam.getFov()
        local dt = GetFrameTime()
        if IsDisabledControlPressed(0, PAD_ZOOM_IN) then FreeCam.setFov(want - PAD_ZOOM_RATE * dt) end
        if IsDisabledControlPressed(0, PAD_ZOOM_OUT) then FreeCam.setFov(want + PAD_ZOOM_RATE * dt) end
    end
    if anyJustPressed(PLACE_TAKE) then
        CreateThread(function() finishPlacing(true) end)
        return
    end
    if anyJustPressed(PLACE_CANCEL) then
        CreateThread(function() finishPlacing(false) end)
        return
    end
    -- The figures ten times a second, not every frame: the box is read, not watched.
    local now = GetGameTimer()
    if now - lastRows >= 100 then
        lastRows = now
        EditorHud.update({ rows = placeRows() })
    end
end

RegisterNUICallback('cfgPlaceCamera', function(data, cb)
    cb('ok')
    if placing or FreeCam.isActive() or type(data) ~= 'table' or type(data.path) ~= 'string' then return end
    local pos, rot = data.pos, data.rot
    placing = { section = type(data.section) == 'string' and data.section or 'config', path = data.path }
    WhipPanelSuspend()
    FreeCam.start({
        hidePed = true, pedFollows = false,
        coords = type(pos) == 'table' and tonumber(pos.x) and pos or nil,
        rot = type(rot) == 'table' and tonumber(rot.x) and rot or nil,
        fov = tonumber(data.fov) or 60.0,
    })
    ControlBlocks.hold('cfgPlaceCamera', { controls = { 191, 201, 200, 202, PAD_ZOOM_IN, PAD_ZOOM_OUT } }, placeFrame)
    EditorHud.show({ house = true, icon = 'camera', title = 'Place camera', sub = data.path,
                     rows = placeRows(), hints = PLACE_HINTS })
end)

-- ---- An arrival scene's Watch ----
--
-- The line as the page has it (unsaved edits too) played where the admin is, as the login would: the panel steps
-- aside for it and comes back when it ends. On foot, in the seat they sit in, or, for a scene made with a car, lined up
-- with the one they sit in or stand by.

local watching = false
local NEAR_VEHICLE = 15.0   -- m: the vehicle a car scene uses when they are not sitting in one

local function nearestVehicle(ped)
    local at, best, bestD = GetEntityCoords(ped), nil, NEAR_VEHICLE
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        local d = #(GetEntityCoords(veh) - at)
        if d < bestD then best, bestD = veh, d end
    end
    return best
end

local function seatOf(veh, ped)
    for seat = -1, GetVehicleModelNumberOfSeats(GetEntityModel(veh)) - 2 do
        if GetPedInVehicleSeat(veh, seat) == ped then return seat end
    end
    return -1
end

local function placeFor(s, ped)
    local inVeh = GetVehiclePedIsIn(ped, false)
    if inVeh ~= 0 then return { veh = inVeh, how = 'seat', seat = seatOf(inVeh, ped) } end
    if s.vehicleClip then
        local veh = nearestVehicle(ped)
        return veh and { veh = veh, how = 'near' } or nil
    end
    return nil
end

local function whyNot(s, place)
    if not Arrival.inGame(s) then return 'The game has no ' .. s.dict .. ' / ' .. s.clip end
    if s.vehicleClip and not place then return 'It is made with a vehicle: stand by one, or sit in it' end
    if place then return 'Not on this seat: a motorbike, bicycle, boat or aircraft has no car seat for it' end
    return 'Not here: in water, or dead'
end

--- A line from the page, kept to what a scene line holds.
local function lineFrom(raw)
    local function name(v) return type(v) == 'string' and #v <= 96 and v:match('^[%w_@%.%-]+$') and v or nil end
    local function part(v) v = tonumber(v); return v and v >= 0 and v <= 1 and v or nil end
    local line = { dict = name(raw.dict), clip = name(raw.clip), cam = name(raw.cam), vehicleClip = name(raw.vehicleClip),
                   from = part(raw.from), to = part(raw.to), getsIn = raw.getsIn == true or nil }
    if not line.dict or not line.clip then return nil end
    return line
end

RegisterNUICallback('cfgArrivalWatch', function(data, cb)
    cb('ok')
    local line = type(data) == 'table' and type(data.line) == 'table' and lineFrom(data.line) or nil
    if watching or not line then return end
    watching = true
    CreateThread(function()
        WhipPanelSuspend()
        local s = Arrival.line(line)
        local ped = PlayerPedId()
        local place = placeFor(s, ped)
        local run = (place or not s.vehicleClip) and Arrival.prepare(place, s) or nil
        if run then Arrival.play(run, nil) else UI.Notify(whyNot(s, place), 'error') end
        WhipPanelResume()
        watching = false
    end)
end)

RegisterNUICallback('cfgApply', function(data, cb)
    cb('ok')
    local changes = type(data) == 'table' and data.changes or nil
    -- The answer goes back to the section that asked ('config', or a satellite's page).
    local sectionId = type(data) == 'table' and type(data.section) == 'string' and data.section or 'config'
    CreateThread(function()
        local ok, res, why = pcall(Callback, 'whip_core:settings:apply', changes)
        if not ok or type(res) ~= 'table' then
            local text = ok and why or 'The settings could not be saved'
            WhipPanelResult(text, 'err')
            WhipPanelData(sectionId, 'applyFailed', { why = text })
            return
        end
        local text = ('Saved %d setting%s.'):format(res.changed or 0, res.changed == 1 and '' or 's')
        local waiting = type(res.waiting) == 'table' and #res.waiting or 0
        if waiting > 0 then
            text = text .. (' %d take%s effect at the next restart.'):format(waiting, waiting == 1 and 's' or '')
        end
        WhipPanelResult(text, 'ok')
        WhipPanelData(sectionId, 'applied', res)
    end)
end)
