-- ============================================
-- /whip SECTION — Containers (client wiring)
-- ============================================
--
-- Replaces tools/containers.lua. The mutation callbacks (cmCreateContainer,
-- cmUpdateContainer, cmDeleteContainer, cmTeleport, cmGetPlayerPos) stay in
-- client/containers.lua with the container runtime they belong to — this file owns
-- only the section lifecycle, the data forward, the inventory handoff, and the set-up
-- wizard's two calls: the props with pictures, and placing one in the world.

PanelSections['containers'] = {
    enter = function()
        TriggerServerEvent('whip_core:server:cmGetAll')
    end,
    leave = function()
        -- No viewer session and no closed event existed for this tool — nothing to say.
    end,
}

RegisterNetEvent('whip_core:client:cmAllData', function(containers)
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    WhipPanelData('containers', 'all', {
        containers = containers,
        pos = { x = c.x, y = c.y, z = c.z, h = GetEntityHeading(ped) },
    })
end)

-- Open a container's inventory from the panel (admin override). Inventory handoff v1:
-- the shell CLOSES rather than suspends — resuming on inventory close needs a clean
-- inventory-closed hook that hasn't been verified; today's UX is preserved exactly.
RegisterNUICallback('cmOpenContainer', function(data, cb)
    WhipPanelClose()
    TriggerServerEvent('whip_core:server:cmOpenContainer', data.containerId)
    cb('ok')
end)

-- ---- The wizard's Model step: the props, with their pictures ----
--
-- The furnisher's catalog as it shows it (Furnisher.catalog, client/property_furnish.lua): the props
-- this game can spawn, each with its name, category and whether a media pack has its picture. The
-- same list the furnisher and the world builder place from, so a container looks like what it is.
RegisterNUICallback('cmPropCatalog', function(_, cb)
    local cat = Furnisher and Furnisher.catalog and Furnisher.catalog() or nil
    cb(type(cat) == 'table' and cat or { props = {}, categories = {} })
end)

-- ---- The wizard's Where step: put it in the world ----
--
-- A see-through copy of the container's prop, where you aim, and the in-world editors' card (EditorHud's house
-- card, as the garage bays and the sign post have) saying the keys, a controller's when one is in hand. It is placed
-- the way the real one will be (client/containers.lua SpawnContainerProp: at the spot, turned, then settled on the
-- ground), so where it stands now is where it will stand. Only this game sees it.

local PLACE_REACH     = 10.0   -- metres: as far as you can aim it
local PLACE_TURN      = 60.0   -- degrees a second: Q / E, or a trigger all the way down (the sign post's)
local PLACE_TURN_FINE = 15.0   -- with Alt
-- On a pad, held while it places: Menu (named, so the pause menu stands aside), X's jump, Y's get-in.
local PLACE_PAD_BLOCK = { controls = { 199, 22, 23 } }

RegisterNUICallback('cmPlace', function(data, cb)
    data = type(data) == 'table' and data or {}
    local prop = type(data.prop) == 'string' and data.prop ~= '' and data.prop or Config.ContainerDefaultProp
    local name = type(data.name) == 'string' and data.name ~= '' and data.name or 'New container'
    local heading = tonumber(data.heading) or ((GetEntityHeading(PlayerPedId()) + 180.0) % 360.0)
    local placed = data.placed == true

    local model = LoadModel(prop)
    if not model then
        cb({ ok = false, why = ('%s is not a model this game can spawn'):format(prop) })
        return
    end

    local ghost, spot, aimed = nil, nil, false
    local pad, padHeld = false, false

    local function card()
        return {
            house = true, icon = 'stash', title = 'Container', sub = name,
            chip = { text = prop },
            rows = {
                { label = 'Aim', value = aimed and ('facing %.0f°'):format(heading) or 'at the ground where it goes',
                  tone = not aimed and 'warn' or nil },
                { label = 'Here', value = spot and ('%.1f, %.1f, %.1f'):format(spot.x, spot.y, spot.z) or 'nowhere yet' },
            },
            hints = {
                { key = 'Enter', pad = 'a', text = 'Put it here', off = spot == nil },
                { key = 'Q / E', pad = { 'lt', 'rt' }, text = 'Turn it' },
                { key = 'Alt', pad = false, text = 'Turn slowly' },
                { key = 'C', pad = 'b', text = 'Cancel' },
            },
        }
    end

    local function holdPad(on)
        if on == padHeld then return end
        padHeld = on
        if on then ControlBlocks.hold('placeContainerPad', PLACE_PAD_BLOCK) else ControlBlocks.release('placeContainerPad') end
    end
    -- A press on the device in hand only: a pad's buttons are keys on a keyboard too, and the reverse.
    local pressed = WhipKeyPressed

    local started = PropertyEditor.start({
        name = 'Container spot',
        hud = card(),
        -- What is read, held off so it does not also fire underneath: the wheel, attack and aim (a pad's
        -- triggers), cover, Q / E (44, 38), reload, melee, Enter (201, 18), Alt (19). C (26) too.
        block = { controls = { 14, 15, 16, 17, 24, 25, 26, 37, 38, 44, 45, 140, 141, 142, 201, 18, 19, 257, 263, 264 } },
        onFrame = (function()
            local nextHud, lastAimed = 0, nil
            return function()
                pad = WhipLastInputIsPad()
                holdPad(pad)
                local dt = GetFrameTime()

                -- Turn it: Q / E held, or the triggers.
                if pad then
                    local t = WhipPadTrigger('rt') - WhipPadTrigger('lt')   -- RT turns it right, LT left
                    if t ~= 0.0 then heading = (heading - t * PLACE_TURN * dt) % 360.0 end
                else
                    local rate = IsDisabledControlPressed(0, 19) and PLACE_TURN_FINE or PLACE_TURN
                    if IsDisabledControlPressed(0, 44) then heading = (heading + rate * dt) % 360.0
                    elseif IsDisabledControlPressed(0, 38) then heading = (heading - rate * dt) % 360.0 end
                end

                -- The map only: the ghost itself must never be what the ray lands on. Aimed at nothing (the sky),
                -- it stands a step in front of you.
                local hit, coords = Interactions.aimRay(PLACE_REACH, 1)
                aimed = hit and true or false
                if not hit then
                    local ped = PlayerPedId()
                    local p = GetEntityCoords(ped)
                    local h = math.rad(GetEntityHeading(ped))
                    coords = vector3(p.x - math.sin(h) * 1.5, p.y + math.cos(h) * 1.5, p.z - 0.95)
                end

                if not ghost or not DoesEntityExist(ghost) then
                    ghost = CreateObject(model, coords.x, coords.y, coords.z, false, false, false)
                    SetEntityAlpha(ghost, 170, false)
                    SetEntityCollision(ghost, false, false)
                    FreezeEntityPosition(ghost, true)
                end
                -- Stood as the real one will stand (client/containers.lua): a placed one exactly at its
                -- spot, every other one snapped to the ground.
                if placed then
                    SetEntityCoordsNoOffset(ghost, coords.x, coords.y, coords.z, false, false, false)
                    SetEntityHeading(ghost, heading)
                else
                    SetEntityCoords(ghost, coords.x, coords.y, coords.z, false, false, false, false)
                    SetEntityHeading(ghost, heading)
                    PlaceObjectOnGroundProperly(ghost)
                end
                spot = coords

                if pressed(201, 201) or (not pad and IsDisabledControlJustPressed(0, 18)) then
                    WhipPanelData('containers', 'spot', { x = spot.x, y = spot.y, z = spot.z, heading = heading })
                    return 'exit'
                end
                -- C / B: back to the wizard, nothing placed. Menu on a pad too (Esc is the mode's own).
                if WhipCancelJustPressed() or (pad and pressed(199, 199)) then return 'exit' end

                -- The card: at once when the aim finds or loses the ground, else five times a second.
                local now = GetGameTimer()
                if aimed ~= lastAimed then nextHud = 0 end
                lastAimed = aimed
                if now >= nextHud then
                    nextHud = now + 200
                    EditorHud.update(card())
                end
            end
        end)(),
        onExit = function()
            holdPad(false)
            if ghost and DoesEntityExist(ghost) then DeleteEntity(ghost) end
            ghost = nil
            SetModelAsNoLongerNeeded(model)
        end,
    })
    if started ~= true then SetModelAsNoLongerNeeded(model) end
    cb({ ok = started == true, why = started ~= true and 'Something else is using the world editor' or nil })
end)
