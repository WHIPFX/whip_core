-- Containers: 3D prop streaming, E-key interaction, NUI callbacks.

local containerDefs  = {}   -- [containerId] = { containerId, name, x, y, z, heading, prop, locked, ... }
local containerProps = {}   -- [containerId] = entity handle
-- Inventory.activeContainerId and ActiveStore are declared in client/inventory.lua (loads first); this file sets
-- them through Inventory.setActiveContainerId, Inventory.confirmPanel's context and Inventory.forgetOpenStore.
local containerPending = false  -- true while waiting for server response to openContainer

-- 3D prop spawning / despawning

--- A container inside an MLO interior (`interior`, opt-in) waits for the interior to be in place, as NPCs do
--- (client/npcs.lua); otherwise the prop lands outside its rooms.
local INTERIOR_SETTLE_MS = 2000
local interiorSince = {}   -- [containerId] = when its interior was first seen there
local function interiorReady(data)
    if not data.interior then return true end
    if GetInteriorAtCoords(data.x, data.y, data.z + 1.0) == 0 then
        interiorSince[data.containerId] = nil
        return false
    end
    local since = interiorSince[data.containerId]
    if not since then
        interiorSince[data.containerId] = GetGameTimer()
        return false
    end
    return GetGameTimer() - since >= INTERIOR_SETTLE_MS
end

local function SpawnContainerProp(data)
    if containerProps[data.containerId] then return end
    -- No prop at all (the room has its own safe): only its prompt.
    if data.prop == false then return end
    -- Not yet: the streamer asks again next pass.
    if not interiorReady(data) then return end

    local modelName = data.prop or Config.ContainerDefaultProp
    local model = LoadModel(modelName)
    if not model then
        print(('[whip_core:container] WARNING: Failed to load model %s for container #%d'):format(modelName, data.containerId))
        return
    end

    -- A placed one exactly at its spot: CreateObject lifts an object by a model-dependent amount (client/property_objects.lua).
    local obj = data.placed and CreateObjectNoOffset(model, data.x, data.y, data.z, false, false, false)
        or CreateObject(model, data.x, data.y, data.z, false, false, false)
    if not obj or obj == 0 then
        SetModelAsNoLongerNeeded(model)
        return
    end

    if not data.placed then SetEntityHeading(obj, data.heading or 0.0) end
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, false, false)
    if data.placed then
        -- Exactly where it was put, tilted as given.
        SetEntityRotation(obj, (data.rx or 0.0) + 0.0, (data.ry or 0.0) + 0.0, (data.heading or 0.0) + 0.0, 2, false)
    else
        PlaceObjectOnGroundProperly(obj)
    end
    SetEntityAsMissionEntity(obj, true, true)

    SetModelAsNoLongerNeeded(model)
    containerProps[data.containerId] = obj
end

local function DespawnContainerProp(containerId)
    local obj = containerProps[containerId]
    if obj then
        if DoesEntityExist(obj) then
            DeleteEntity(obj)
        end
        containerProps[containerId] = nil
    end
end

-- Where a stash's prompt sits on its prop
-- Placed from the prop's model box (GetModelDimensions) in one of three ways, each player's choice (pause menu,
-- Settings, Server, Map & HUD, Stash prompt), defaulting to the server's Config.ContainerPrompt:
--   'middle'  A billboard at the middle of the box, pulled toward the camera (Interactions `pull`) by as far as
--             the box reaches toward you, so it shows from every side. The default.
--   'side'    A sign flat on the middle of the nearest wall (Interactions `heading`), at the camera's height,
--             held inside the wall's top and bottom, circle and words centred (Interactions `centre`). It
--             snaps to another side only once that one is clearly nearer.
--   'face'    The same sign sliding round the whole outline with you (onOutline), rolling round corners.
-- Both signs wrap round corners: the world renderer gets the box as seen from that side (Interactions `wrap`;
-- interact_world.lua, foldQuad).
-- This is the interaction system's `follow` (client/interact.lua), asked once a frame while the prompt is
-- on screen. With no prop out the spot is used.

local PROMPT_CLEAR  = 0.05   -- 'middle': metres in front of the prop's face it is pulled to
local FACE_OFF      = 0.02   -- the signs: metres off the wall, so a sign never sinks into it
local FACE_EDGE     = 0.12   -- the signs: how far inside the wall's top and bottom they keep
local FACE_STICK    = 1.15   -- 'side': another side wins only once it is this much more yours

local STASH_PROMPTS = { middle = true, side = true, face = true }
PlayerPrefs.define({
    key = 'prompts.stash', group = 'Map & HUD', type = 'choice', label = 'Stash prompt',
    help = 'Where the E prompt sits on a stash: in the middle, seen through it; flat on the side facing you, at eye level; or following you round it, wrapping round its corners.',
    options = {
        { value = 'middle', label = 'In the middle' },
        { value = 'side', label = 'Faces towards you' },
        { value = 'face', label = 'Follows you' },
    },
    default = function()
        return STASH_PROMPTS[Config.ContainerPrompt] and Config.ContainerPrompt or 'middle'
    end,
})
local modelBoxes = {}        -- [model] = its box's middle, half-sizes, bottom and top; read once

--- The side of the box you are on: 1/2 = right / left wall, 3/4 = front / back; `lx, ly` = where you stand
--- from its middle, along its right and forward.
local function nearestSide(b, lx, ly, side)
    local sx = math.abs(lx) / math.max(b.hx, 0.05)
    local sy = math.abs(ly) / math.max(b.hy, 0.05)
    local onX = sx >= sy
    -- Stays on the same pair of walls until the other pair is clearly nearer (FACE_STICK).
    if side then
        local wasX = side <= 2
        if wasX ~= onX and (onX and sx or sy) < (onX and sy or sx) * FACE_STICK then onX = wasX end
    end
    if onX then return lx >= 0 and 1 or 2 end
    return ly >= 0 and 3 or 4
end

--- 'face', wrapped: where on the box's outline the prompt stands. Level with you along a side; rolled round a
--- corner by your angle to it. HX, HY: the box's half-sizes grown by the sign's gap; corners are rounded by R
--- for this alone. Answers the side (as nearestSide numbers it) and `t`, how far along it from its middle
--- (forward on sides 1/2, right on 3/4), or nil when you stand inside the box.
local FACE_ROUND = 0.2   -- metres either side of a corner the roll round it takes
local QUARTER = math.pi / 2
local function onOutline(HX, HY, lx, ly)
    local R = math.min(FACE_ROUND, HX * 0.45, HY * 0.45)
    local IX, IY = HX - R, HY - R
    local inX, inY = math.abs(lx) <= IX, math.abs(ly) <= IY
    if inX and inY then return nil end
    -- s: distance round the outline, anticlockwise from the back-left corner (-HX, -HY).
    local s
    if inX then
        s = ly < 0 and (lx + HX) or (2 * HX + 2 * HY + (HX - lx))
    elseif inY then
        s = lx > 0 and (2 * HX + (ly + HY)) or (4 * HX + 2 * HY + (HY - ly))
    else
        -- A corner: how far round it you are (0 to a quarter turn).
        local vx, vy = lx - (lx > 0 and IX or -IX), ly - (ly > 0 and IY or -IY)
        local c, th
        if lx > 0 and ly < 0 then c, th = 2 * HX, math.atan(vx, -vy)
        elseif lx > 0 then c, th = 2 * HX + 2 * HY, math.atan(vy, vx)
        elseif ly > 0 then c, th = 4 * HX + 2 * HY, math.atan(-vx, vy)
        else c, th = 4 * HX + 4 * HY, math.atan(-vy, -vx) end
        s = c - R + (th / QUARTER) * 2 * R
    end
    s = s % (4 * HX + 4 * HY)
    if s < 2 * HX then return 4, -HX + s end
    s = s - 2 * HX
    if s < 2 * HY then return 1, -HY + s end
    s = s - 2 * HY
    if s < 2 * HX then return 3, HX - s end
    return 2, HY - (s - 2 * HX)
end

--- `v` held inside [lo, hi], or the middle when the span is too narrow.
local function within(v, lo, hi)
    if lo > hi then return (lo + hi) / 2 end
    return math.max(lo, math.min(hi, v))
end

local function modelBox(model)
    local b = modelBoxes[model]
    if b then return b end
    local mn, mx = GetModelDimensions(model)
    b = { cx = (mn.x + mx.x) / 2, cy = (mn.y + mx.y) / 2, hx = (mx.x - mn.x) / 2, hy = (mx.y - mn.y) / 2,
          hz = (mx.z - mn.z) / 2, bottom = mn.z, top = mx.z }
    modelBoxes[model] = b
    return b
end

--- The `follow` for one container's prompt: where it stands this frame (pull, facing and wrap box), or nil (stay put).
local function promptFollow(cId)
    local side, sideAt = nil, 0   -- the signs: the wall it is on, and when it was last asked
    local wrap = {}               -- the signs: the box round it, for the renderer to wrap on (one table, reused)
    return function()
        -- Its prop, or a property stash's furniture piece (client/property_objects.lua).
        local obj = containerProps[cId] or (PropertyStashEntity and PropertyStashEntity(cId))
        if not obj or not DoesEntityExist(obj) then return nil end
        local b = modelBox(GetEntityModel(obj))
        local pos = GetEntityCoords(obj)
        local hd = math.rad(GetEntityHeading(obj))
        local ex, ey = math.cos(hd), math.sin(hd)        -- the prop's right
        local fx, fy = -math.sin(hd), math.cos(hd)       -- the prop's forward
        local bx = pos.x + ex * b.cx + fx * b.cy         -- its box's middle, on the ground plan
        local by = pos.y + ey * b.cx + fy * b.cy
        local cam = GetFinalRenderedCamCoord()
        local mode = PlayerPrefs.get('prompts.stash')

        if mode ~= 'side' and mode ~= 'face' then
            side = nil
            -- Middle: how far the box reaches toward the camera along the view.
            local bz = pos.z + (b.bottom + b.top) / 2
            local vx, vy, vz = cam.x - bx, cam.y - by, cam.z - bz
            local len = math.sqrt(vx * vx + vy * vy + vz * vz)
            if len < 0.01 then return bx, by, bz end
            vx, vy, vz = vx / len, vy / len, vz / len
            local reach = math.abs(vx * ex + vy * ey) * b.hx + math.abs(vx * fx + vy * fy) * b.hy + math.abs(vz) * b.hz
            -- Never less than the prompt's own pull.
            local least = (Config.Interact3D and Config.Interact3D.depthBias) or 0.30
            return bx, by, bz, nil, math.max(reach + PROMPT_CLEAR, least)
        end

        -- A sign on a side; lx, ly = where you stand from the box's middle.
        local me = GetEntityCoords(PlayerPedId())
        local px, py = me.x - bx, me.y - by
        local lx, ly = px * ex + py * ey, px * fx + py * fy
        -- 'face': round the outline with you (onOutline). 'side', or inside the box: the side you are on, at its middle.
        local onSide, along = nil, nil
        if mode == 'face' then onSide, along = onOutline(b.hx + FACE_OFF, b.hy + FACE_OFF, lx, ly) end
        local now = GetGameTimer()
        if now - sideAt > 500 then side = nil end   -- back on screen: the side you are on now
        sideAt = now
        side = onSide or nearestSide(b, lx, ly, side)
        -- The wall: facing (nx, ny), distance out, and its along-direction.
        local nx, ny, out, ax, ay, half
        if side == 1 then nx, ny, out, ax, ay, half = ex, ey, b.hx, fx, fy, b.hy
        elseif side == 2 then nx, ny, out, ax, ay, half = -ex, -ey, b.hx, fx, fy, b.hy
        elseif side == 3 then nx, ny, out, ax, ay, half = fx, fy, b.hy, ex, ey, b.hx
        else nx, ny, out, ax, ay, half = -fx, -fy, b.hy, ex, ey, b.hx end
        -- Along it: level with you ('face') or its middle ('side'). Up it: the camera's height, inside its top and bottom.
        local t = onSide and along or 0.0
        local lo, hi = pos.z + b.bottom, pos.z + b.top
        local edgeZ = math.min(FACE_EDGE, (hi - lo) * 0.25)
        local z = within(cam.z, lo + edgeZ, hi - edgeZ)
        local d = out + FACE_OFF
        -- Wrapped round the box: the box as seen from this side, grown by the sign's gap.
        local w = wrap
        w.ox, w.oy = bx + nx * d, by + ny * d
        w.ax, w.ay, w.tx, w.ty = ax, ay, -nx, -ny
        w.lo, w.hi = -(half + FACE_OFF), half + FACE_OFF
        w.depth = 2 * d
        -- A sign facing straight out of the wall: GTA's heading for (nx, ny). Not pulled (pull 0). 'side' centres
        -- circle and words on the side's middle (Interactions `centre`); 'face' keeps the circle on its point.
        return bx + nx * d + ax * t, by + ny * d + ay * t, z, math.deg(math.atan(-nx, ny)), 0.0, w, mode == 'side'
    end
end

-- Interactions API: register containers as interaction points (declared before the sync events that call them)

local function registerContainerInteraction(cId, data)
    Interactions.register({
        id = 'container_' .. cId,
        x = data.x,
        y = data.y,
        z = data.z,
        follow = promptFollow(cId),   -- round its prop, on your side (above)
        label = data.name or 'Container',
        icon = 'stash',               -- a box opening (html/js/glyphs.js), not the bare E
        group = 'containers',
        -- `containerPending` is not part of this condition: a request lost to the rate limiter would hide the prompt
        -- until a timeout (see Vehicles.tryOpenGlovebox).
        condition = function()
            local d = containerDefs[cId]
            -- A property's stash: only for the people who live there (the server checks again).
            return d and not d.locked and not IsAnyUIOpen()
                and (not d.property or (LivesInProperty ~= nil and LivesInProperty(d.property)))
        end,
        callback = function()
            -- Drawn from memory before the ask, so a stash opened before appears at once (as in client/inventory.lua).
            Inventory.drawRememberedPanel({
                key  = 'container:' .. tostring(cId),
                open = 'openInventoryWithContainer',
            })

            -- The request is debounced, the panel is not.
            if not containerPending then
                containerPending = true
                TriggerServerEvent('whip_core:server:openContainer', cId)

                -- The same undo a refusal gets: a rate-limited open is dropped with no reply, so this timer is
                -- the only thing that runs for it. Clearing `containerPending` alone is not enough: the intent
                -- from Inventory.drawRememberedPanel would make Inventory.confirmPanel decline every other
                -- panel (see the Denied handler below).
                SetTimeout(5000, function()
                    if not containerPending then return end
                    containerPending = false
                    if Inventory.hasOptimisticPanel() then Inventory.close() end
                    Inventory.cancelPanelOpen()
                end)
            end
        end,
    })
end

local function registerContainerInteractions()
    Interactions.removeGroup('containers')
    for id, data in pairs(containerDefs) do
        registerContainerInteraction(id, data)
    end
end

-- Server to client: sync events

--- Full sync (on connect/load)
RegisterNetEvent('whip_core:client:containersSync', function(containers)
    containerDefs = {}
    if containers then
        for id, data in pairs(containers) do
            containerDefs[tonumber(id)] = data
        end
    end
    registerContainerInteractions()
end)

--- Single container created (broadcast from server)
RegisterNetEvent('whip_core:client:containerCreated', function(data)
    if not data or not data.containerId then return end
    containerDefs[data.containerId] = data
    registerContainerInteraction(data.containerId, data)
end)

--- Single container updated (broadcast from server)
RegisterNetEvent('whip_core:client:containerUpdated', function(data)
    if not data or not data.containerId then return end
    -- Despawn the old prop (model or position may have changed)
    DespawnContainerProp(data.containerId)
    containerDefs[data.containerId] = data
    Interactions.remove('container_' .. data.containerId)
    registerContainerInteraction(data.containerId, data)
end)

--- Single container deleted (broadcast from server)
RegisterNetEvent('whip_core:client:containerDeleted', function(containerId)
    if not containerId then return end
    containerDefs[containerId] = nil
    interiorSince[containerId] = nil
    DespawnContainerProp(containerId)
    Interactions.remove('container_' .. containerId)
end)

-- Streaming: spawn/despawn is handled by the shared StreamProps thread (client/streamprops.lua)

StreamProps.addStream({
    name      = 'containers',
    -- Getters, not the tables: containersSync above rebinds containerDefs wholesale.
    defs      = function() return containerDefs end,
    range     = function() return Config.ContainerStreamRange or 100.0 end,
    isSpawned = function(id) return containerProps[id] ~= nil end,
    spawn     = SpawnContainerProp,
    despawn   = DespawnContainerProp,
})

-- Container opened: the server sends data, the inventory UI opens

RegisterNetEvent('whip_core:client:openContainerDenied', function()
    containerPending = false

    -- The stash may already be on screen, drawn from memory. A refusal (locked, in use) takes that back;
    -- the server pushes its own toast saying why.
    if Inventory.hasOptimisticPanel() then Inventory.close() end

    -- The intent is cleared even when nothing was drawn: Inventory.drawRememberedPanel records `panelWanted`
    -- when a panel is asked for. A first-time stash sets it and draws nothing, so Inventory.hasOptimisticPanel()
    -- is false and Inventory.close never runs; the stale intent then makes Inventory.confirmPanel
    -- (`panelWanted ~= nil and panelWanted ~= spec.key`) decline every other panel (see client/vehicles.lua).
    Inventory.cancelPanelOpen()
end)

RegisterNetEvent('whip_core:client:openContainer', function(data)
    containerPending = false
    if not data then
        Inventory.setActiveContainerId(nil)
        return
    end

    -- The server has already taken the container's exclusive lock. If OpenInventoryUI declines (another UI is up),
    -- Inventory.activeContainerId is never set and nothing releases the lock, so the container reads as in use
    -- until restart. A declined open must therefore send a release; Inventory.confirmPanel answers false for
    -- every case where nothing went on screen (including closed or changed panel while this travelled).
    if not Inventory.confirmPanel({
        key     = data.containerId and ('container:' .. tostring(data.containerId)) or nil,
        open    = 'openInventoryWithContainer',
        sync    = 'swapSecondaryPanel',
        context = { containerId = data.containerId },
    }, data) then
        TriggerServerEvent('whip_core:server:closeContainer', data.containerId)
    end
end)

--- A resource opened one of its own store kinds (OpenStore). The payload is a stash's shape plus `storeAddr`.
RegisterNetEvent('whip_core:client:openStore', function(data)
    if type(data) ~= 'table' or type(data.storeAddr) ~= 'table' or not data.storeId then return end
    local store = {
        kind    = data.storeAddr.kind,
        id      = data.storeAddr.id,
        sub     = data.storeAddr.sub,
        storeId = data.storeId,
    }
    -- Declining owes the server a release, as for a stash.
    if not Inventory.confirmPanel({
        key     = data.storeId,
        open    = 'openInventoryWithContainer',
        sync    = 'swapSecondaryPanel',
        context = { store = store },
    }, data) then
        TriggerServerEvent('whip_core:server:closeStore', data.storeId)
    end
end)

--- A resource took a store away (CloseStore). The server already released it, so the matching Active* is
--- cleared first (else Inventory.close sends a close that is logged as refused), then the screen closes if it was on it.
RegisterNetEvent('whip_core:client:storeClosed', function(storeId)
    if type(storeId) ~= 'string' then return end
    if Inventory.forgetOpenStore(storeId) then Inventory.close() end
end)

--- Server sends updated container inventory (after move)
RegisterNetEvent('whip_core:client:containerUpdate', function(data)
    if not data then return end

    -- Keep the remembered copy current while open, so reopening shows what was just moved.
    if Inventory.activeContainerId then
        Inventory.patchRememberedPanel('container:' .. tostring(Inventory.activeContainerId), {
            containerInv    = data.inventory,
            containerWeight = data.containerWeight,
        })
    end

    SendNUIMessage({
        action = 'containerUpdate',
        data   = data,
    })
end)

-- NUI callbacks: container operations

-- Addresses are built by Inventory.storeAddr (client/inventory.lua), one mapping shared by every path.

RegisterNUICallback('containerMoveItem', function(data, cb)
    TriggerServerEvent('whip_core:server:storeMove',
        Inventory.storeAddr(data.fromContainer, data.fromSlot, data.containerId),
        Inventory.storeAddr(data.toContainer,   data.toSlot,   data.containerId),
        0, 'move', data.opId or 0
    )
    cb('ok')
end)

RegisterNUICallback('containerDropOneItem', function(data, cb)
    TriggerServerEvent('whip_core:server:storeMove',
        Inventory.storeAddr(data.fromContainer, data.fromSlot, data.containerId),
        Inventory.storeAddr(data.toContainer,   data.toSlot,   data.containerId),
        0, 'one', data.opId or 0
    )
    cb('ok')
end)

-- Container manager tool: NUI callbacks

RegisterNUICallback('cmTeleport', function(data, cb)
    local x = tonumber(data.x) or 0
    local y = tonumber(data.y) or 0
    local z = tonumber(data.z) or 0
    SetEntityCoords(PlayerPedId(), x, y, z, false, false, false, false)
    cb('ok')
end)

--- How far a prop reaches out from where it stands, in metres: half its footprint's diagonal. Sent with an admin's
--- create or change, so the server counts the open range from its edge, where its prompt is (Containers.openFor).
--- nil when the model is not in the game or does not load in time.
---@param prop string|false|nil
---@return number|nil
local function propReach(prop)
    if type(prop) ~= 'string' or prop == '' then return nil end
    local model = GetHashKey(prop)
    if not IsModelInCdimage(model) then return nil end
    RequestModel(model)
    local untilAt = GetGameTimer() + 2000
    while not HasModelLoaded(model) and GetGameTimer() < untilAt do Wait(0) end
    if not HasModelLoaded(model) then return nil end
    local lo, hi = GetModelDimensions(model)
    SetModelAsNoLongerNeeded(model)
    local hx = math.max(math.abs(lo.x), math.abs(hi.x))
    local hy = math.max(math.abs(lo.y), math.abs(hi.y))
    return math.sqrt(hx * hx + hy * hy)
end

RegisterNUICallback('cmCreateContainer', function(data, cb)
    cb('ok')
    if type(data) ~= 'table' then return end
    CreateThread(function()
        data.reach = propReach(data.prop or Config.ContainerDefaultProp)
        TriggerServerEvent('whip_core:server:createContainer', data)
    end)
end)

-- /whip's Containers, opened by an admin (its list, tools/panel_sections/containers.lua): a saved container whose prop
-- was never measured is measured here and sent, so it opens from its edge as one set up since does.
RegisterNetEvent('whip_core:client:cmAllData', function(containers)
    if type(containers) ~= 'table' then return end
    CreateThread(function()
        local found, byProp, any = {}, {}, false
        for id, c in pairs(containers) do
            if type(c) == 'table' and c.reach == nil and c.persist ~= false and type(c.prop) == 'string' and c.prop ~= '' then
                if byProp[c.prop] == nil then byProp[c.prop] = propReach(c.prop) or false end
                local cId = tonumber(c.containerId) or tonumber(id)
                if byProp[c.prop] and cId then
                    found[cId] = byProp[c.prop]
                    any = true
                end
            end
        end
        if any then TriggerServerEvent('whip_core:server:cmContainerReach', found) end
    end)
end)

RegisterNetEvent('whip_core:client:cmContainerCreated', function(def)
    -- Into the /whip Containers section (selects the new row).
    WhipPanelData('containers', 'created', def)
end)

RegisterNUICallback('cmUpdateContainer', function(data, cb)
    cb('ok')
    if type(data) ~= 'table' then return end
    local id = tonumber(data.containerId)
    CreateThread(function()
        -- Measured at every save, so one made before the reach was kept gets it the next time it is changed.
        local prop = data.prop
        if prop == nil then
            local d = id and containerDefs[id]
            prop = d and d.prop
        end
        data.reach = propReach(prop)
        TriggerServerEvent('whip_core:server:updateContainer', id, data)
    end)
end)

RegisterNUICallback('cmDeleteContainer', function(data, cb)
    TriggerServerEvent('whip_core:server:deleteContainer', tonumber(data.containerId))
    cb('ok')
end)

RegisterNUICallback('cmGetPlayerPos', function(_, cb)
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    cb({ x = c.x, y = c.y, z = c.z, h = GetEntityHeading(ped) })
end)

-- Ignition: NUI callbacks

--- The ignition is a one-slot vehicle store, addressed like any other. Inserting a key makes the engine
--- startable through the vehicle kind's afterMove hook.
local function ignitionAddr(vehicleId)
    return { kind = 'vehicle', id = vehicleId, sub = 'key', slot = 1 }
end

-- The other side may be a bag (a resource's panel, `panelId`): Inventory.nuiStoreAddr names it.
RegisterNUICallback('ignitionInsertKey', function(data, cb)
    TriggerServerEvent('whip_core:server:storeMove',
        Inventory.nuiStoreAddr(data.fromContainer, data.fromSlot, data.containerId, data.panelId),
        ignitionAddr(data.vehicleId),
        0, 'move', data.opId or 0)
    cb('ok')
end)

RegisterNUICallback('ignitionRemoveKey', function(data, cb)
    TriggerServerEvent('whip_core:server:storeMove',
        ignitionAddr(data.vehicleId),
        Inventory.nuiStoreAddr(data.toContainer, data.toSlot, data.containerId, data.panelId),
        0, 'move', data.opId or 0)
    cb('ok')
end)

--- Expose containerDefs for tools/client.lua
function GetContainerDefs()
    return containerDefs
end

-- Cleanup on resource stop

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        for _, obj in pairs(containerProps) do
            if DoesEntityExist(obj) then
                DeleteEntity(obj)
            end
        end
        containerProps = {}
    end
end)
