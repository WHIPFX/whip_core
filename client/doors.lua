-- ============================================
-- Door System — Client
-- Push-synced door cache, DoorSystem native
-- integration.
--
-- Nothing here asks the server for doors. The full (projected) set arrives once at login and
-- again on core restart (doorsSync); creates, updates and deletes are broadcast; lock changes
-- arrive for doors whose cell we hold (doorStateChanged) or as we gain cells (doorStatesBatch).
-- ============================================

local clientDoors     = {}    -- [doorId] = door data — EVERY door, seven wire fields
local nearbyDoors     = {}    -- [doorId] = door data — the subset within DOOR_RANGE.
                              -- Rebuilt each proximity tick, so per-frame scans walk only the
                              -- handful around the player.
local registeredDoors = {}    -- [doorId] = doorHash (registered with DoorSystem)
local DOOR_RANGE      = 50.0  -- range to register/unregister DoorSystem natives
local DOOR_NATIVE_CAP = 40    -- most DoorSystem slots whip holds at once (the engine has 75 in all)
local DOOR_PROMPT_RANGE = 15.0 -- doors within this, in 3D, get their two handle prompts
local DOOR_PROMPT_CAP   = 24   -- and at most this many doors, nearest first (two prompts each)
TotalDoorCount        = 0     -- global: total door count, from doorsSync (for editor HUD)

-- ============================================
-- Door Hash Generation
-- ============================================

local function makeDoorHash(x, y, z)
    return GetHashKey(('%.2f_%.2f_%.2f'):format(x, y, z))
end

-- ============================================
-- DoorSystem Native Wrappers
-- ============================================

--- Doors whose registration we have already complained about, so the retry below stays quiet.
--- Cleared when a door finally registers, so a door that recovers can complain again if it breaks
--- a second time.
local registerWarned = {}

--- Put a door into GTA's DoorSystem, and CHECK THAT IT WENT IN.
---
--- AddDoorToSystem fails SILENTLY (the door budget exhausted, or another script has claimed that
--- physical door under a different key), and a door recorded as registered when it is not ignores
--- every lock while the UI and server say it is locked. So it is checked, and only recorded if it
--- went in.
---
--- Not recording a failure is also the retry: the proximity thread calls this once a second for
--- every door in range.
---@param door table
local function registerDoorNative(door)
    if registeredDoors[door.doorId] then return end
    local doorHash = makeDoorHash(door.x, door.y, door.z)

    AddDoorToSystem(doorHash, door.model, door.x, door.y, door.z, false, false, false)

    if not IsDoorRegisteredWithSystem(doorHash) then
        if not registerWarned[door.doorId] then
            registerWarned[door.doorId] = true
            print(('[whip_core:doors] door %s ("%s") REFUSED by the DoorSystem at %.2f %.2f %.2f — '
                .. 'its locks will not work. Another resource has probably claimed the same door '
                .. 'under a different key, or MaxDoorExtensions (75) is exhausted.')
                :format(tostring(door.doorId), tostring(door.label or '?'), door.x, door.y, door.z))
        end
        return
    end

    registerWarned[door.doorId] = nil
    DoorSystemSetDoorState(doorHash, door.locked and 1 or 0, false, false)
    registeredDoors[door.doorId] = doorHash
end

local function unregisterDoorNative(doorId)
    local doorHash = registeredDoors[doorId]
    registerWarned[doorId] = nil
    if not doorHash then return end
    DoorSystemSetDoorState(doorHash, 0, false, false) -- unlock before removing
    RemoveDoorFromSystem(doorHash)
    registeredDoors[doorId] = nil
end

--- Push a lock state at a door that is actually registered.
---
--- Silent when it is not: a door out of range has no native to write to, and a bad registration is
--- caught at registration time.
local function applyDoorState(doorId, locked)
    local doorHash = registeredDoors[doorId]
    if not doorHash then return end
    DoorSystemSetDoorState(doorHash, locked and 1 or 0, false, false)
end

-- ============================================
-- Find door by entity
-- ============================================

local function getDoorByEntity(entity)
    if not entity or entity == 0 then return nil end
    local model = GetEntityModel(entity)
    local pos = GetEntityCoords(entity)
    -- The nearby subset, not the full cache: an entity you can aim at is inside DOOR_RANGE.
    -- The nearest within 2 m, not whichever pairs() gave first (two same-model leaves of an
    -- unlinked double door).
    local best, bestSq = nil, 4.0   -- 2m tolerance
    for _, door in pairs(nearbyDoors) do
        if door.model == model then
            local dx = door.x - pos.x
            local dy = door.y - pos.y
            local dz = door.z - pos.z
            local dsq = dx * dx + dy * dy + dz * dz
            if dsq < bestSq then best, bestSq = door, dsq end
        end
    end
    return best
end

-- ============================================
-- Proximity Detection Thread
-- ============================================

--- Forward-declared: the thread below is written before these exist, and would otherwise compile
--- their names as globals (nil at runtime). `doorPrompts` lives up here for the same reason.
local addDoorPrompts, removeDoorPrompts
local doorPrompts = {}   -- [doorId] = { idA, idB }

CreateThread(function()
    -- Wait for player to load
    while not PlayerLoaded do Wait(500) end
    Wait(2000)

    -- Purely local, once a second: keep DoorSystem natives registered for doors around the
    -- player, and maintain the `nearbyDoors` subset the per-frame consumers scan.
    while true do
        local pos = GetEntityCoords(PlayerPedId())

        local subset, inRange = {}, {}
        local rangeSq = DOOR_RANGE * DOOR_RANGE
        for doorId, door in pairs(clientDoors) do
            local dx = door.x - pos.x
            local dy = door.y - pos.y
            if (dx * dx + dy * dy) <= rangeSq then
                subset[doorId] = door
                local dz = door.z - pos.z
                inRange[#inRange + 1] = { door = door, d = dx * dx + dy * dy + dz * dz }
            else
                unregisterDoorNative(doorId)
                removeDoorPrompts(doorId)
            end
        end
        nearbyDoors = subset

        -- The DoorSystem gets the nearest doors (75 slots in all, and a flat 50m counts every floor
        -- of a tower): nearest first, in 3D, capped, and a farther door gives its slot up.
        table.sort(inRange, function(a, b) return a.d < b.d end)
        local keep = {}
        for i = 1, math.min(#inRange, DOOR_NATIVE_CAP) do keep[inRange[i].door.doorId] = true end
        for doorId in pairs(registeredDoors) do
            if not keep[doorId] then unregisterDoorNative(doorId) end
        end
        for i = 1, math.min(#inRange, DOOR_NATIVE_CAP) do registerDoorNative(inRange[i].door) end

        -- Prompts for the doors around you, not the whole tower: nearest first, in 3D, within
        -- DOOR_PROMPT_RANGE, capped. Fifteen metres at one check a second leaves ten metres of
        -- warning before a circle could first show, even at a sprint.
        local promptKeep = {}
        local promptRangeSq = DOOR_PROMPT_RANGE * DOOR_PROMPT_RANGE
        for i = 1, math.min(#inRange, DOOR_PROMPT_CAP) do
            if inRange[i].d > promptRangeSq then break end
            promptKeep[inRange[i].door.doorId] = inRange[i].door
        end
        for doorId in pairs(doorPrompts) do
            if not promptKeep[doorId] then removeDoorPrompts(doorId) end
        end
        for _, door in pairs(promptKeep) do addDoorPrompts(door) end

        Wait(1000)
    end
end)


-- ============================================
-- Door Interaction — a circle on each handle
-- ============================================
--
-- Each door registers two interaction points, one per face, and the shared system does the
-- scoring, the focus cone, the fade and the key. What is special about doors is only this:
--
--   They move. A door swings, so its prompt cannot be a fixed coordinate — it is registered with
--   a `follow` that reads the live entity every frame and returns where the handle is NOW and
--   which way that face is pointing. See Interactions.register.
--
--   They are signs, not billboards. `follow` returns a heading, so the circle stays flat against
--   the door and turns with it. Walk past and it goes edge-on; stand behind it and it is not
--   drawn, which is right — that handle is on the other side.
--
--   They say nothing. An empty label means no text quad is ever allocated; the colour a door
--   flashes says what happened. A garage door is the exception: "Open Garage" / "Close Garage".
--
-- The two faces are separate registrations rather than one double-sided prompt, because the
-- interaction system's cull is per-prompt and each face genuinely has its own position.

local doorInteractCooldown = 0
-- doorPrompts ([doorId] = { idA, idB }) is declared above the proximity thread, which reads it.

local _derivedOffsets = {}   -- [model] = { x, y, z }; a model's dimensions never change

--- The handle's offset inside the door's own model, worked out from the model itself.
---
--- Derived, not tabulated: for a hinged door the origin sits at the hinge, so the free edge is
--- whichever of min.x/max.x is further from zero, and the handle lives near it at about waist
--- height. Wrong on things that are not ordinary hinged doors (double gates, shutters):
--- Config.DoorPromptOffsets keys a hand-measured {x, y, z} off the model hash for those.
---@param model number
---@return number x, number y, number z
local function handleOffset(model)
    local override = (Config.DoorPromptOffsets or {})[model]
    if override then return override.x, override.y, override.z end

    -- Once per model: this runs from `follow`, every frame, for both faces of every door on screen.
    local memo = _derivedOffsets[model]
    if memo then return memo[1], memo[2], memo[3] end

    local minDim, maxDim = GetModelDimensions(model)
    if not minDim or not maxDim then return 0.45, 0.06, 1.0 end

    -- Whichever side of the origin the door body actually extends to.
    local far = (math.abs(maxDim.x) >= math.abs(minDim.x)) and maxDim.x or minDim.x
    local x = far * (Config.DoorHandleAlong or 0.85)

    -- Half the panel's thickness, plus a little, so the circle sits ON the face rather than
    -- inside it — a quad coplanar with the door would z-fight along its whole surface.
    local y = (math.max(math.abs(maxDim.y), math.abs(minDim.y)) or 0.05) + 0.02

    -- Waist height, measured up from the bottom of the model rather than from the origin, since
    -- some door origins sit at the floor and some at the centre.
    local z = minDim.z + (Config.DoorHandleHeight or 1.05)

    _derivedOffsets[model] = { x, y, z }
    return x, y, z
end

-- ============================================
-- Garage doors: the padlock rides the door
-- ============================================
--
-- A garage door has no handle, and it opens UP, not round. So on a garage-sized door (wider than
-- GARAGE_MIN_WIDTH, as the property wizard's scan sizes them, tools/interior.lua) it does what a
-- stash's 'face' prompt does along a box (client/containers.lua): it slides across the door with the
-- player, level with them along its width and kept off its edges, at handle height, on the face they
-- stand at. And it lies on the door: placed in the door's own frame, facing the door's own forward
-- (not just its heading), so as the door tilts up the padlock tilts with it (the interaction
-- system's `tilt`, client/interact.lua). A hand-measured spot (Config.DoorPromptOffsets) still wins.

local GARAGE_MIN_WIDTH = 1.7   -- metres: wider than any single door the probe measured (0.92-1.21)
local GARAGE_EDGE      = 0.45  -- metres kept clear of each end of the door, at most

local _garageBox = {}   -- [model] = { lo, hi, front, back, z } or false; a model's box never changes

--- A garage-sized door's box: how far it runs across (lo..hi), where its two faces are, and the
--- padlock's height. Nil for any other door.
local function garageBox(model)
    local g = _garageBox[model]
    if g == nil then
        local mn, mx = GetModelDimensions(model)
        -- Not read yet (no size at all): asked again next time, rather than remembered as no garage.
        if not mn or not mx or (mx.x - mn.x) <= 0.01 then return nil end
        g = false
        if (mx.x - mn.x) > GARAGE_MIN_WIDTH and (mx.z - mn.z) >= 1.6
            and not (Config.DoorPromptOffsets or {})[model] then
            g = {
                lo = mn.x, hi = mx.x,
                -- Just off each face, as a handle's circle is (a quad on the face would z-fight it).
                front = mx.y + 0.02, back = mn.y - 0.02,
                z = math.min(mx.z - 0.3, mn.z + (Config.DoorHandleHeight or 1.05)),
            }
        end
        _garageBox[model] = g
    end
    return g or nil
end

--- Where a garage door's padlock is on this face, and which way it faces: x, y, z, heading, tilt.
local function garageFollow(obj, g, side)
    local me = GetEntityCoords(PlayerPedId())
    local loc = GetOffsetFromEntityGivenWorldCoords(obj, me.x, me.y, me.z)
    local edge = math.min(GARAGE_EDGE, (g.hi - g.lo) * 0.25)
    local lx = math.max(g.lo + edge, math.min(g.hi - edge, loc.x))
    local p = GetOffsetFromEntityInWorldCoords(obj, lx, side > 0 and g.front or g.back, g.z)
    -- The face's outward normal in 3D: the door's own forward (local +Y), tilted however far it has
    -- swung up, turned round for the back face. GET_ENTITY_MATRIX answers FORWARD FIRST (forward,
    -- right, up, position); a door swings up round its right axis.
    local fwd = GetEntityMatrix(obj)
    local nx, ny, nz = fwd.x * side, fwd.y * side, fwd.z * side
    local heading = math.deg(math.atan(-nx, ny)) % 360.0
    local tilt = math.deg(math.asin(math.max(-1.0, math.min(1.0, nz))))
    return p.x, p.y, p.z, heading, tilt
end

-- A handle setting changed in /whip → Settings: every door works its handle out again on its next
-- frame.
Settings.onChange('DoorHandleAlong', function() _derivedOffsets = {} end)
Settings.onChange('DoorHandleHeight', function() _derivedOffsets = {}; _garageBox = {} end)
Settings.onChange('DoorPromptOffsets', function() _derivedOffsets = {}; _garageBox = {} end)

--- The live door object, if it is streamed in.
---
--- Looked up at most once a second per door, and trusted in between only while it still exists
--- (doors stream in and out with the world).
local _doorObj = {}   -- [doorId] = { obj, at }
local DOOR_OBJ_TTL_MS = 1000

local function doorEntity(door)
    local now = GetGameTimer()
    local c = _doorObj[door.doorId]
    if c and now - c.at < DOOR_OBJ_TTL_MS and DoesEntityExist(c.obj) then return c.obj end

    local obj = GetClosestObjectOfType(door.x, door.y, door.z, 1.5, door.model, false, false, false)
    if obj == 0 or not DoesEntityExist(obj) then
        _doorObj[door.doorId] = nil
        return nil
    end
    _doorObj[door.doorId] = { obj = obj, at = now }
    return obj
end

--- Register both faces of a door as interaction points.
--- Assignment, not `local function` — the local is forward-declared above the proximity thread.
function addDoorPrompts(door)
    if doorPrompts[door.doorId] then return end
    if not Interactions then return end

    local ids = {}
    for i, side in ipairs({ 1.0, -1.0 }) do
        local id = ('door_%d_%s'):format(door.doorId, side > 0 and 'a' or 'b')
        ids[i] = id

        Interactions.register({
            id    = id,
            x     = door.x, y = door.y, z = door.z,   -- seed; `follow` supersedes it every frame
            -- No text, except a garage door says what E does: "Open Garage" while it is locked,
            -- "Close Garage" while it is not. Asked as it is drawn, so it
            -- reads the lock as it is now; any other door answers '' and draws no words at all.
            label = function()
                local d = clientDoors[door.doorId]
                if d and garageBox(d.model) then return d.locked and 'Open Garage' or 'Close Garage' end
                return ''
            end,
            group = 'doors',

            -- Position, not aim: you walk up to a door; you do not line one up.
            focusMode = 'near',

            -- A padlock, not a key letter: what is worth knowing is whether it is locked. The badge
            -- atlas draws these as icons (html/interact3d/badge.html).
            icon = door.locked and 'lock' or 'unlock',

            --- Where this face's handle is, right now, and which way it faces.
            follow = function()
                local d = clientDoors[door.doorId]
                if not d then return nil end
                local obj = doorEntity(d)
                if not obj then return nil end

                -- A garage door: along the door with the player, lying on it (above).
                local g = garageBox(d.model)
                if g then
                    local gx, gy, gz, gh, gt = garageFollow(obj, g, side)
                    return gx, gy, gz, gh, nil, nil, nil, gt
                end

                local ox, oy, oz = handleOffset(d.model)
                local p = GetOffsetFromEntityInWorldCoords(obj, ox, oy * side, oz)

                -- The face's outward normal in world terms. Local +Y is the entity's forward, so
                -- the front face reads the door's heading and the back face is 180 from it.
                local h = GetEntityHeading(obj)
                if side < 0 then h = h + 180.0 end

                return p.x, p.y, p.z, h % 360.0
            end,

            callback = function()
                if GetGameTimer() <= doorInteractCooldown then return end
                doorInteractCooldown = GetGameTimer() + 500
                TriggerServerEvent('whip_core:server:doorToggle', door.doorId)
            end,
        })
    end

    doorPrompts[door.doorId] = ids
end

--- Assignment, not `local function` — forward-declared above the proximity thread.
function removeDoorPrompts(doorId)
    _doorObj[doorId] = nil
    local ids = doorPrompts[doorId]
    if not ids then return end
    for _, id in ipairs(ids) do Interactions.remove(id) end
    doorPrompts[doorId] = nil
end

--- Flash both of a door's circles the same colour.
---
--- Both, because you cannot know which face the player is looking at and the answer belongs to
--- the door rather than to one of its handles.
local function flashDoor(doorId, r, g, b)
    local ids = doorPrompts[doorId]
    if not ids then return end
    for _, id in ipairs(ids) do Interactions.flash(id, r, g, b) end
end

--- Point both of a door's circles at the padlock that matches its current state.
local function syncDoorIcon(doorId, locked)
    local ids = doorPrompts[doorId]
    if not ids then return end
    local icon = locked and 'lock' or 'unlock'
    for _, id in ipairs(ids) do Interactions.updateIcon(id, icon) end
end

-- ============================================
-- Server Events
-- ============================================

-- Is the Door Manager dev tool on screen? DoorManagerOpen is set only by tools/zones.lua (unset,
-- with the tool file deleted, reads as closed). html/js/doors.js keeps its own `dmOpen` flag.

--- Repaint the Door Manager, but only when someone is looking at it: GetAllDoorsForTool is a
--- BLOCKING fetch of the whole door table. The world's state is applied from the event arguments.
local function refreshDoorNUI()
    if not DoorManagerOpen then return end
    SendNUIMessage({ action = 'dmRefresh', doors = GetAllDoorsForTool() })
end

-- Door state changed (from server broadcast)
RegisterNetEvent('whip_core:client:doorStateChanged', function(doorId, locked)
    if clientDoors[doorId] then
        clientDoors[doorId].locked = locked
        applyDoorState(doorId, locked)

        -- The answer, in colour: green for unlocked, red for locked, fading back to white. Driven
        -- from the SERVER'S announcement, not the key press (what happened, not what was asked),
        -- and for changes this player did not cause too. The padlock swaps first, so the new
        -- state shows through the colour.
        syncDoorIcon(doorId, locked)

        if locked then
            flashDoor(doorId, 248, 113, 113)   -- --ui-error
        else
            flashDoor(doorId, 74, 222, 128)    -- --ui-success
        end
    end
    refreshDoorNUI()
end)

--- SOMEBODY was refused at this door: no permission, wrong job, missing key.
---
--- Not necessarily you: this fires for everyone in range of the door (somebody rattling a handle is
--- worth noticing). The reason is not sent to onlookers; the toast goes to the one who tried.
---
--- Amber rather than red (red means "locked"; a refusal changed nothing).
RegisterNetEvent('whip_core:client:doorDenied', function(doorId)
    flashDoor(doorId, 251, 191, 36)            -- --ui-warning
end)

--- The full door set — at login, and again whenever core restarts underneath us.
---
--- A wholesale rebind, like shopsSync (client/shops.lua), except `registeredDoors` holds live
--- DoorSystem handles, so a door that vanished meanwhile must release its native registration.
--- Rebinding the locals is safe: consumers read them as upvalues at call time.
RegisterNetEvent('whip_core:client:doorsSync', function(doors)
    local fresh, count = {}, 0
    if type(doors) == 'table' then
        for _, d in ipairs(doors) do
            if d and d.doorId then
                fresh[d.doorId] = d
                count = count + 1
            end
        end
    end

    -- Release natives for doors the new world does not contain.
    for doorId in pairs(registeredDoors) do
        if not fresh[doorId] then unregisterDoorNative(doorId) end
    end

    clientDoors = fresh
    TotalDoorCount = count

    -- Re-apply state to surviving registrations. On a core restart the sync may carry lock
    -- states that changed while our scripts were down — and makeDoorHash is position-derived,
    -- so the same hash re-applies cleanly over whatever the previous script instance left in
    -- the DoorSystem.
    for doorId in pairs(registeredDoors) do
        if clientDoors[doorId] then
            applyDoorState(doorId, clientDoors[doorId].locked)
        end
    end

    -- Next proximity tick rebuilds the subset against the fresh table.
    nearbyDoors = {}

    -- And the prompts with it, so a deleted door does not keep a point in the interaction grid.
    for doorId in pairs(doorPrompts) do removeDoorPrompts(doorId) end

    refreshDoorNUI()
end)

--- Lock states for doors in cells we just gained — the catch-up half of the scoped announce.
--- See Doors.getStatesInCells and the sweep in server/events_inventory.lua. No nearest-prompt
--- repaint here: a just-gained cell sits ~75m+ out, never the ≤2.5m nearest door.
RegisterNetEvent('whip_core:client:doorStatesBatch', function(states)
    if type(states) ~= 'table' then return end
    for _, s in ipairs(states) do
        local door = clientDoors[s.doorId]
        if door then
            door.locked = s.locked
            applyDoorState(s.doorId, s.locked)
            -- No flash: states for cells just streamed in, 75m+ away. The padlock still updates.
            syncDoorIcon(s.doorId, s.locked)
        end
    end
    refreshDoorNUI()
end)

-- New door created
RegisterNetEvent('whip_core:client:doorCreated', function(door)
    clientDoors[door.doorId] = door
    TotalDoorCount = TotalDoorCount + 1

    -- Into the world NOW when it is beside us, not at the next 1s tick: the in-world editor's
    -- save-then-link flow aims at the door it just placed, and GetClientDoor({ entity = }) reads the
    -- nearby subset.
    local pos = GetEntityCoords(PlayerPedId())
    local dx, dy = door.x - pos.x, door.y - pos.y
    if (dx * dx + dy * dy) <= (DOOR_RANGE * DOOR_RANGE) then
        nearbyDoors[door.doorId] = door
        registerDoorNative(door)
    end

    refreshDoorNUI()
end)

-- Door updated
RegisterNetEvent('whip_core:client:doorUpdated', function(doorId, door)
    if clientDoors[doorId] then
        for k, v in pairs(door) do
            clientDoors[doorId][k] = v
        end
        applyDoorState(doorId, clientDoors[doorId].locked)
    else
        clientDoors[doorId] = door
    end
    -- The subset points at the same table when the merge branch ran; the else branch made a
    -- new one, so re-point any stale subset entry at it.
    if nearbyDoors[doorId] then nearbyDoors[doorId] = clientDoors[doorId] end
    refreshDoorNUI()
end)

-- Door deleted
RegisterNetEvent('whip_core:client:doorDeleted', function(doorId)
    unregisterDoorNative(doorId)
    removeDoorPrompts(doorId)
    clientDoors[doorId] = nil
    nearbyDoors[doorId] = nil
    TotalDoorCount = math.max(0, TotalDoorCount - 1)
    refreshDoorNUI()
end)

-- Lockpick offer
--
-- The attempt is one server event: the server runs the minigame through its verified SkillCheck
-- (pushing the ring to this screen), judges the result, and unlocks the door itself. The item check
-- here is only courtesy feedback; the server verifies the lockpick itself.
RegisterNetEvent('whip_core:client:doorLockpickOffer', function(doorId)
    if Inventory.hasItemFlag('lockpick') then
        TriggerServerEvent('whip_core:server:doorLockpickAttempt', doorId)
    else
        UI.Notify('You need a lockpick', 'error', 2000)
    end
end)

-- ============================================
-- Exports
-- ============================================

--- Is this door locked? nil for an unknown id.
---
--- For a far door the answer is "as of the last cell we shared": lock changes are announced only to
--- players near the door. Within ~125m this is always current (server/doors.lua's updateState);
--- gate nothing that matters on a far door's answer: ask the server (doorToggleLocked).
---@param doorId number
---@return boolean|nil locked  nil for an unknown id
exports('IsDoorLocked', function(doorId)
    local d = clientDoors[doorId]
    if not d then return nil end
    return d.locked == true
end)

--- Doors near a point: `(x, y, z, range)` or `(coords, range)` (the server export's shapes), or just
--- `(range)`, measured from the player. 25 m by default on both sides.
exports('GetDoorsNearby', function(a, b, c, d)
    local px, py, range
    if type(a) == 'vector3' or type(a) == 'vector4' or type(a) == 'table' then
        px, py, range = tonumber(a.x), tonumber(a.y), b
    elseif c ~= nil then
        px, py, range = tonumber(a), tonumber(b), d
    else
        local pos = GetEntityCoords(PlayerPedId())
        px, py, range = pos.x, pos.y, a
    end
    if not (px and py) then return {}, 'GetDoorsNearby needs a point: (range), (coords, range) or (x, y, z, range)' end
    range = tonumber(range) or 25.0
    local rangeSq = range * range
    local result = {}
    for _, door in pairs(clientDoors) do
        local dx = door.x - px
        local dy = door.y - py
        if (dx * dx + dy * dy) <= rangeSq then
            result[#result + 1] = door
        end
    end
    return result
end)

--- A door from the client's cache: by its doorId, or `{ entity = }` for the saved door a world entity is (by
--- model and position, among the doors nearby). Global as well: the door and object tools read it without the
--- export.
---@param ref number|{ entity: number }|nil
---@return table|nil
function GetClientDoor(ref)
    if type(ref) == 'table' then return getDoorByEntity(ref.entity) end
    return clientDoors[ref]
end

exports('GetLoadedDoors', function()
    local result = {}
    for _, door in pairs(clientDoors) do
        result[#result + 1] = door
    end
    return result
end)

exports('GetDoor', function(ref) return GetClientDoor(ref) end)

--- The last list the server gave — what a refused read answers instead (see below).
local lastToolDoors = nil

-- Internal: get all doors for dev tool (fetches ALL from server, not just nearby)
--
-- A refused (rate-limited) read is not "no doors": it answers the last list it had, so the manager's
-- list does not go blank mid-edit.
function GetAllDoorsForTool()
    local allDoors = Callback('whip_core:getDoorAll')
    if type(allDoors) ~= 'table' then return lastToolDoors or {} end
    TotalDoorCount = #allDoors
    table.sort(allDoors, function(a, b)
        local fa = a.folder or ''
        local fb = b.folder or ''
        if fa ~= fb then return fa < fb end
        return (a.label or '') < (b.label or '')
    end)
    lastToolDoors = allDoors
    return allDoors
end
