-- ============================================
-- /whip SECTION — Shops (client wiring)
-- ============================================
--
-- Register enter/leave into PanelSections, forward the tool's existing server
-- responses through WhipPanelData (no focus, no open dance — the shell owns those),
-- and carry the tool's mutation NUI callbacks. Every server event named here is
-- UNCHANGED from the standalone Shop Manager this section replaced — the server
-- never noticed the consolidation. The old smClose callback did not move: the shell
-- owns close, and the section leave fires smClosed.

PanelSections['shops'] = {
    enter = function()
        TriggerServerEvent('whip_core:server:smGetAll')
    end,
    leave = function()
        TriggerServerEvent('whip_core:server:smClosed')
    end,
}

RegisterNetEvent('whip_core:client:smAllShops', function(data)
    WhipPanelData('shops', 'all', data)
end)

RegisterNetEvent('whip_core:client:smRefresh', function(data)
    WhipPanelData('shops', 'refresh', data)
end)

-- ---- mutations (moved verbatim from tools/misc_tools.lua) ----

RegisterNUICallback('smCreateShop', function(data, cb)
    TriggerServerEvent('whip_core:server:smCreateShop', data)
    cb('ok')
end)

RegisterNUICallback('smUpdateShop', function(data, cb)
    TriggerServerEvent('whip_core:server:smUpdateShop', data.shopId, data)
    cb('ok')
end)

RegisterNUICallback('smDeleteShop', function(data, cb)
    TriggerServerEvent('whip_core:server:smDeleteShop', data.shopId)
    cb('ok')
end)

RegisterNUICallback('smTeleport', function(data, cb)
    SetEntityCoords(PlayerPedId(), data.x, data.y, data.z, false, false, false, false)
    SetEntityHeading(PlayerPedId(), data.heading or 0.0)
    cb('ok')
end)

RegisterNUICallback('smGetPlayerPos', function(_, cb)
    local coords = GetEntityCoords(PlayerPedId())
    local heading = GetEntityHeading(PlayerPedId())
    cb({ x = coords.x, y = coords.y, z = coords.z, heading = heading })
end)

-- ============================================
-- The set-up wizard
-- ============================================
--
-- "+ New Shop" is a wizard now, like the property Configurator's (html/js/wp/shops.js). Two of its
-- steps are done in the world, each a PropertyEditor mode (tools/property_editor.lua): the panel is
-- suspended for it, the editor HUD says which keys do what, and Esc comes back to the panel.
--
--   Where      walk to where the shopkeeper will stand, face the customers, press E
--   Shopkeeper see the picked NPC standing on that spot, through a camera, and flip through the list

-- Create and Save answer the wizard (the shop's id, or why not), so it can open the shop when it is
-- made; and it reads a stock room's prices for its Prices step. One shape: { ok, why, ... }.
local function ask(name, ...)
    local res, why = Callback(name, ...)
    if type(res) ~= 'table' then res = { ok = false, why = why or 'The server did not answer' } end
    return res
end

RegisterNUICallback('smWizardCreate', function(data, cb)
    cb(ask('whip_core:smWizardCreate', data))
end)

RegisterNUICallback('smWizardUpdate', function(data, cb)
    cb(ask('whip_core:smWizardUpdate', type(data) == 'table' and data.shopId, type(data) == 'table' and data.data))
end)

RegisterNUICallback('smStockPrices', function(data, cb)
    cb(ask('whip_core:smStockPrices', type(data) == 'table' and data.containerId))
end)

-- ---- Where: stand on the spot ----

local SPOT_GROUP = 'sm_spot'   -- no prompt is in it: setSolo hides the others while a mode runs

RegisterNUICallback('smPlaceSpot', function(data, cb)
    local name = type(data) == 'table' and type(data.name) == 'string' and data.name ~= '' and data.name or 'New shop'
    local nextAt = 0
    local started = PropertyEditor.start({
        name = 'Shop spot',
        solo = SPOT_GROUP,
        hud = {
            house = true, icon = 'pin', title = 'Shopkeeper spot',
            sub = 'Stand where they will stand, facing their way', chip = { text = name },
            rows = {},
            -- Enter (A on a pad), as the other placers put things down.
            hints = {
                { key = 'Enter', pad = 'a', text = 'They stand here' },
                { key = 'C', pad = 'b', text = 'Cancel' },
            },
        },
        -- Enter (201, 18) and C (26) read, held off so they do not also fire underneath; melee too, which a
        -- pad's B also is. Walking is left alone: you walk to the spot.
        block = { controls = { 18, 26, 140, 141, 142, 201 } },
        onFrame = function()
            local ped = PlayerPedId()
            local c = GetEntityCoords(ped)
            local h = GetEntityHeading(ped)
            -- The keeper's feet: a ring with an arrow pointing the way they will face.
            DrawMarker(26, c.x, c.y, c.z - 0.97, 0.0, 0.0, 0.0, 0.0, 0.0, h, 0.9, 0.9, 0.9,
                255, 255, 255, 170, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
            local now = GetGameTimer()
            if now >= nextAt then
                nextAt = now + 250
                EditorHud.update({ rows = {
                    { label = 'Here', value = ('%.1f, %.1f, %.1f'):format(c.x, c.y, c.z) },
                    { label = 'Facing', value = ('%.0f°'):format(h) },
                } })
            end
            if WhipKeyPressed(201, 201) or (not WhipLastInputIsPad() and IsDisabledControlJustPressed(0, 18)) then
                WhipPanelData('shops', 'spot', { x = c.x, y = c.y, z = c.z, heading = h })
                return 'exit'
            end
            if WhipCancelJustPressed() then return 'exit' end
        end,
    })
    cb({ ok = started == true })
end)

-- ---- Shopkeeper: see them in the world ----
--
-- A ped only this game has (not networked), standing on the shop's spot doing what the real keeper
-- does, and a camera in front of it. ←/→ (or the wheel, or the d-pad) shows the next one in the list
-- the wizard was showing; the mouse turns the camera round them; E keeps the one shown.

local PREVIEW_SCENARIO = 'WORLD_HUMAN_STAND_IMPATIENT'   -- the real keeper's (server/shop_counters.lua)
local PREVIEW_LOAD_MS = 5000                              -- a model that takes longer is called missing
local PREVIEW_DISTANCE = 3.0                              -- metres, camera to keeper: the whole body in view

RegisterNUICallback('smPreviewKeeper', function(data, cb)
    local list = type(data) == 'table' and type(data.list) == 'table' and data.list or {}
    if #list == 0 then cb({ ok = false, why = 'There is nobody in the list to show' }) return end
    local index = math.tointeger(tonumber(data.index)) or 1
    if index < 1 or index > #list then index = 1 end
    local shopName = type(data.name) == 'string' and data.name ~= '' and data.name or 'New shop'

    -- On the shop's spot, or a few steps in front of you if it has none yet.
    local x, y, z, h = tonumber(data.x), tonumber(data.y), tonumber(data.z), tonumber(data.heading)
    if not (x and y and z) then
        local you = PlayerPedId()
        local c = GetEntityCoords(you)
        local ph = GetEntityHeading(you)
        x = c.x - math.sin(math.rad(ph)) * 2.5
        y = c.y + math.cos(math.rad(ph)) * 2.5
        z = c.z
        h = (ph + 180.0) % 360.0   -- facing you
    end
    h = h or 0.0

    local ped, cam = nil, nil
    local token = 0        -- which show() is current: a slow load finishing late is thrown away
    local orbit = 0.0      -- degrees the camera has been turned round them
    local live = true

    local function entry(i)
        local e = list[i]
        if type(e) ~= 'table' then return '', '' end
        return tostring(e.m or ''), tostring(e.n or e.m or '')
    end

    local function removePed()
        if ped and DoesEntityExist(ped) then DeleteEntity(ped) end
        ped = nil
    end

    -- How the one shown stands, in the card's chip: loading, ready, or why not.
    local function showHud(status, tone)
        local model, name = entry(index)
        EditorHud.update({
            chip = { text = status, tone = tone },
            rows = {
                { label = 'Who', value = name },
                { label = 'Model', value = model },
                { label = 'Look', value = ('%d of %d'):format(index, #list) },
            },
        })
    end

    local function show()
        token = token + 1
        local mine = token
        local model = entry(index)
        local hash = GetHashKey(model)
        if not (IsModelInCdimage(hash) and IsModelAPed(hash)) then
            removePed()
            showHud('Not in this game', 'warn')
            return
        end
        showHud('Loading')
        CreateThread(function()
            LoadModel(hash, PREVIEW_LOAD_MS)   -- whip's loader, not a hand-written loop (audit 20, ARC-1)
            if mine ~= token or not live then
                SetModelAsNoLongerNeeded(hash)
                return
            end
            if not HasModelLoaded(hash) then
                removePed()
                showHud('Did not load', 'warn')
                return
            end
            removePed()
            ped = CreatePed(4, hash, x, y, z, h, false, false)
            SetModelAsNoLongerNeeded(hash)
            if not ped or ped == 0 then
                ped = nil
                showHud('Could not be made', 'warn')
                return
            end
            FreezeEntityPosition(ped, true)
            SetEntityInvincible(ped, true)
            SetBlockingOfNonTemporaryEvents(ped, true)
            TaskStartScenarioInPlace(ped, PREVIEW_SCENARIO, 0, true)
            showHud('Ready', 'ok')
        end)
    end

    local function placeCam()
        if not cam then return end
        local a = math.rad(h + orbit)
        SetCamCoord(cam, x - math.sin(a) * PREVIEW_DISTANCE, y + math.cos(a) * PREVIEW_DISTANCE, z + 0.25)
        PointCamAtCoord(cam, x, y, z - 0.1)
    end

    local started = PropertyEditor.start({
        name = 'Shopkeeper preview',
        solo = SPOT_GROUP,
        padBack = true,   -- B goes back, as Esc does
        hud = {
            house = true, icon = 'ped', title = 'Shopkeeper', sub = shopName,
            rows = {},
            hints = {
                { key = '← / →', pad = { 'dpad_left', 'dpad_right' }, text = 'Next look' },
                { key = 'Mouse', pad = 'rs', text = 'Turn round' },
                { key = Interactions.keyName(), pad = 'a', text = 'Choose them' },   -- the Interact key (WhipAcceptJustPressed)
                { key = 'Esc', pad = 'b', text = 'Back' },
            },
        },
        onExit = function()
            live = false
            token = token + 1
            removePed()
            if cam then
                RenderScriptCams(false, true, 400, true, true)
                DestroyCam(cam, false)
                cam = nil
            end
            ClearFocus()
        end,
        -- Everything held off, so walking, shooting and the wheel do nothing underneath; what the preview reads it
        -- reads disabled. The mode's block, as the property modes do.
        block = { all = true },
        onFrame = function()
            SetEntityLocallyInvisible(PlayerPedId())   -- you may be standing on the very spot

            local turn = GetDisabledControlNormal(0, 1)
            if turn ~= 0.0 then
                orbit = (orbit + turn * 6.0) % 360.0
                placeCam()
            end
            if IsDisabledControlJustPressed(0, 175) or IsDisabledControlJustPressed(0, 16) then
                index = index % #list + 1
                show()
            elseif IsDisabledControlJustPressed(0, 174) or IsDisabledControlJustPressed(0, 17) then
                index = (index - 2) % #list + 1
                show()
            end
            -- Choose: the Interact key (E unless moved) or Enter on a keyboard, A on a pad. Not 38: on a pad that is LB,
            -- whip's combo key.
            if WhipAcceptJustPressed() or WhipKeyPressed(201, nil) then
                if ped then WhipPanelData('shops', 'keeper', { model = (entry(index)) }) end
                return 'exit'
            end
        end,
    })
    if not started then cb({ ok = false, why = 'Something else is using the screen' }) return end

    SetFocusPosAndVel(x, y, z, 0.0, 0.0, 0.0)   -- the world streams in round the spot, wherever you are
    cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamFov(cam, 45.0)
    placeCam()
    RenderScriptCams(true, true, 400, true, true)
    show()
    cb({ ok = true })
end)
