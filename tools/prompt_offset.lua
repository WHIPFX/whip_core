PromptOffsetEditor = {}

local edit, opening
local ID = 'prompt_offset_preview'
local MODEL = GetHashKey('prop_cs_cardbox_01')

local function finish()
    local e = edit
    if not e then return end
    edit = nil
    if e.move and OvMove.active() then OvMove.stop() end
    if e.camera and FreeCam.isActive() then FreeCam.stop({ movePed = false }) end
    Interactions.remove(ID)
    if Interactions.getPreview() == ID then Interactions.setPreview(nil) end
    if DoesEntityExist(e.marker) then DeleteEntity(e.marker) end
    PedHold.release(ID)
    ControlBlocks.release(ID)
    if e.back then e.back() end
end

local function values(e)
    local p = GetEntityCoords(e.marker)
    local offset = GetOffsetFromEntityGivenWorldCoords(e.entity, p.x, p.y, p.z)
    local heading = (GetEntityHeading(e.marker) - GetEntityHeading(e.entity)) % 360.0
    if e.editingVisual then
        return e.offset, heading, vector3(offset.x - e.offset.x, offset.y - e.offset.y, offset.z - e.offset.z)
    end
    return offset, heading, e.visualOffset
end

local function caption(e)
    return ('%s | radius %.2f m | %s'):format(e.editingVisual and 'Label position' or 'Interaction point',
        e.radius, e.billboard and 'faces camera' or 'sign')
end

local function printValues()
    local e = edit
    if not e or not DoesEntityExist(e.entity) then finish() return end
    local offset, heading, visual = values(e)
    local fields = ('offset = vector3(%.4f, %.4f, %.4f)'):format(offset.x, offset.y, offset.z)
    fields = fields .. (', visualOffset = vector3(%.4f, %.4f, %.4f), radius = %.2f'):format(visual.x, visual.y, visual.z, e.radius)
    fields = fields .. (e.billboard and ', heading = false' or (', heading = %.2f'):format(heading))
    local key = e.name ~= '' and ('[%q]'):format(e.name) or ('[%d]'):format(e.model)
    local text = ('WHIP action:\nat = { entity = entity, %s }\n\n'
        .. 'Entry in Config.PropPromptDefaultOffset:\n%s = { %s },'):format(fields, key, fields)
    print('[whip_core:promptoffset]\n' .. text)
    finish()
end

local function start(entity, back)
    local untilAt = GetGameTimer() + 5000
    RequestModel(MODEL)
    while not HasModelLoaded(MODEL) and GetGameTimer() < untilAt do Wait(0) end
    if not HasModelLoaded(MODEL) then
        SetModelAsNoLongerNeeded(MODEL)
        return false, 'Could not load the preview marker'
    end
    if not DoesEntityExist(entity) or not DevToolsOn() then
        SetModelAsNoLongerNeeded(MODEL)
        return false, 'The entity or developer mode is no longer available'
    end
    if OvMove.active() or FreeCam.isActive() or Interactions.getPreview() then
        SetModelAsNoLongerNeeded(MODEL)
        return false, 'Close the other editor first'
    end
    local model = GetEntityModel(entity)
    local offset, heading, visualOffset, radius = PromptOffset.resolve(model)
    local p
    if offset then
        p = GetOffsetFromEntityInWorldCoords(entity, offset.x, offset.y, offset.z)
    else
        local low, high = GetModelDimensions(model)
        p = GetOffsetFromEntityInWorldCoords(entity, (low.x + high.x) / 2, low.y - 0.05, (low.z + high.z) / 2)
    end
    local marker = CreateObjectNoOffset(MODEL, p.x, p.y, p.z, false, false, false)
    SetModelAsNoLongerNeeded(MODEL)
    if not marker or marker == 0 then return false, 'Could not make the preview marker' end
    edit = { entity = entity, marker = marker, model = model, billboard = offset ~= nil and not heading, back = back,
             visualOffset = visualOffset or vector3(0.0, 0.0, 0.0), radius = radius or 0.25 }
    edit.name = GetEntityArchetypeName(entity) or ''
    SetEntityCollision(marker, false, false)
    SetEntityVisible(marker, false, false)
    FreezeEntityPosition(marker, true)
    SetEntityHeading(marker, (GetEntityHeading(entity) + (heading or 180.0)) % 360.0)
    PedHold.set(ID, { frozen = true })
    ControlBlocks.hold(ID, { controls = { 0, 27, 172, 173 } })
    local cam, rot = GetFinalRenderedCamCoord(), GetFinalRenderedCamRot(2)
    edit.camera = true
    FreeCam.start({ hidePed = false, pedFollows = false, coords = cam, rot = rot })
    FreeCam.setInputEnabled(false)
    local e = edit
    local registered, reason = Interactions.register({
        id = ID, group = ID, x = p.x, y = p.y, z = p.z, label = 'Use', icon = 'E',
        visibleRange = 50.0, activeRange = 50.0, focusMode = 'near', callback = function() end,
        sizeRange = Config.InteractActiveRange or 3.0,
        follow = function()
            if edit ~= e or not DoesEntityExist(marker) then return nil end
            local offset, heading, visual = values(e)
            local at = GetOffsetFromEntityInWorldCoords(entity, offset.x + visual.x, offset.y + visual.y, offset.z + visual.z)
            return at.x, at.y, at.z, not e.billboard and GetEntityHeading(marker) or nil
        end,
    })
    if registered == false then return false, reason end
    Interactions.setPreview(ID, function()
        local at = GetFinalRenderedCamCoord()
        return at.x, at.y, at.z
    end)
    local ok, why = OvMove.start({
        entity = marker, kind = 'object', tilt = false, name = e.name ~= '' and e.name or tostring(model),
        caption = caption(e), doneText = 'Print & Exit', onDone = printValues,
        keys = {
            { key = 'R', text = 'Rotate / Move' },
            { key = 'H', text = 'Face camera / Sign' },
            { key = 'V', text = 'Point / Label' },
            { key = 'Up / Down', text = 'Radius' },
            { key = 'Right mouse', text = 'Look' },
            { key = 'Esc', text = 'Cancel' },
        },
    }, finish)
    if not ok then return false, why end
    e.move = true
    CreateThread(function()
        while edit == e do
            local ran, err = pcall(function()
                if not DevToolsOn() or not DoesEntityExist(entity) or not DoesEntityExist(marker) then finish() return end
                FreeCam.setInputEnabled(IsDisabledControlPressed(0, 25) or IsControlPressed(0, 25))
                if IsControlJustPressed(0, 74) or IsDisabledControlJustPressed(0, 74) then
                    e.billboard = not e.billboard
                    OvMove.update({ caption = caption(e) })
                end
                if IsControlJustPressed(0, 0) or IsDisabledControlJustPressed(0, 0) then
                    local offset, heading, visual = values(e)
                    e.offset, e.visualOffset = offset, visual
                    e.editingVisual = not e.editingVisual
                    local p = GetOffsetFromEntityInWorldCoords(entity,
                        offset.x + (e.editingVisual and visual.x or 0.0),
                        offset.y + (e.editingVisual and visual.y or 0.0),
                        offset.z + (e.editingVisual and visual.z or 0.0))
                    SetEntityCoordsNoOffset(marker, p.x, p.y, p.z, false, false, false)
                    OvMove.update({ caption = caption(e) })
                end
                local grow = IsControlJustPressed(0, 172) or IsDisabledControlJustPressed(0, 172)
                local shrink = IsControlJustPressed(0, 173) or IsDisabledControlJustPressed(0, 173)
                if grow or shrink then
                    e.radius = math.max(0.01, math.min(5.0, e.radius + (grow and 0.05 or -0.05)))
                    OvMove.update({ caption = caption(e) })
                end
                local offset, heading, visual = values(e)
                local point = GetOffsetFromEntityInWorldCoords(entity, offset.x, offset.y, offset.z)
                local diameter = e.radius * 2.0
                DrawMarker(28, point.x, point.y, point.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    diameter, diameter, diameter, 80, 190, 255, 70, false, false, 2, false, nil, nil, false)
                local at = GetOffsetFromEntityInWorldCoords(entity, offset.x + visual.x, offset.y + visual.y, offset.z + visual.z)
                Interactions.updatePosition(ID, at.x, at.y, at.z)
            end)
            if not ran then
                print('[whip_core:promptoffset] ' .. tostring(err))
                finish()
            end
            Wait(0)
        end
    end)
    return true
end

function PromptOffsetEditor.open(entity, back)
    if not DevToolsOn() then return false, 'Enable developer mode with /w first' end
    if edit or opening or OvMove.active() or FreeCam.isActive() or Interactions.getPreview() then
        return false, 'Close the other editor first'
    end
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false, 'Look at an entity first' end
    opening = true
    local ran, ok, why = pcall(start, entity, back)
    opening = nil
    if not ran or not ok then
        if edit then edit.back = nil end
        finish()
        return false, ran and why or tostring(ok)
    end
    return true
end

RegisterCommand('promptoffset', function()
    if edit then finish() return end
    if not DevToolsOn() then UI.Notify('Enable developer mode with /w first', 'error') return end
    local kinds, flags = AimBox.kinds({ 'object', 'vehicle', 'ped' })
    local out = {}
    local hit = AimBox.aim(kinds, flags, 20.0, nil, out)
    local entity = hit and out.entity or nil
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        entity = nil
        local at = GetEntityCoords(PlayerPedId())
        local nearest = 20.0 * 20.0
        for _, prop in ipairs(GetGamePool('CObject')) do
            if DoesEntityExist(prop) then
                local p = GetEntityCoords(prop)
                local x, y, z = p.x - at.x, p.y - at.y, p.z - at.z
                local distance = x * x + y * y + z * z
                if distance <= nearest then entity, nearest = prop, distance end
            end
        end
    end
    if not entity then UI.Notify('No prop within 20 m. Move closer or look at an entity.', 'error') return end
    local ok, why = PromptOffsetEditor.open(entity)
    if not ok then UI.Notify(why, 'error') end
end, false)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        if edit then edit.back = nil end
        finish()
    end
end)
