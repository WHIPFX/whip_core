-- ============================================
-- Client Spawn Logic — client/spawn.lua
-- Complete the join handshake, then show character selection NUI.
--
-- whip owns the whole spawn, with no `spawnmanager` (see CompleteJoinSpawn below).
-- ============================================

local hasSpawnedInitial = false

--- Did this resource start into a session that was ALREADY running?
---
--- Evaluated once, during load, not inside a handler. Two routes can open the character screen (the
--- playerSpawned handler and the onClientResourceStart handler at the bottom of this file), and on a
--- restart both fire; exactly one must win, and deciding it in a handler would be a race.
---
--- Safe if the answer is "wrong" (a fresh join can have the session up already): both routes end in
--- ShowCharacterSelect, and both read the SAME answer.
local isRestart = NetworkIsSessionStarted()

--- Has CompleteJoinSpawn finished: the loading screen gone and the picture black? The restart
--- route waits for it before the landing page, which must not come up under the loading screen or
--- be blacked out by the spawn's fade. Declared up here so CompleteJoinSpawn can set it.
local joinSpawnDone = false

-- How far the ground is allowed to be from the position we were asked for before the snap below
-- decides it has found the WRONG ground and leaves well alone. A stored position is normally
-- within a few centimetres of the floor; metres away means an upper storey, a rooftop or an
-- interior, where the nearest ground is the street underneath the whole building.
local GROUND_SNAP_MAX = 3.0

-- Longest we will hold the black waiting for a spawned ped to stop moving. It normally breaks
-- out on the first check; this is only the ceiling for a spawn the snap could not help.
local SETTLE_MAX_MS = 600

-- THE WORLD AT THE SPOT BEFORE THE PED IS LET GO. Collision round the ped is the ground's; a deck, a
-- platform or a building's upper floor is part of the map's scene, which streams in after it (a first
-- load on a far-off spot, on a slow line, takes seconds). So the scene round the spot is loaded too
-- (SCENE_RADIUS), for up to WORLD_WAIT_MAX_MS; then, up to FLOOR_WAIT_MS more, a floor must be under
-- their feet (within GROUND_SNAP_MAX), or water. A spot with no floor at all (a mid-air save) is let
-- go at the end of that.
local SCENE_RADIUS      = 60.0
local WORLD_WAIT_MAX_MS = 10000
local FLOOR_WAIT_MS     = 2000

--- What they will stand on at (x, y, z): true and its height, true and nil in water, or false.
local function floorAt(x, y, z)
    local wet, waterZ = GetWaterHeight(x, y, z + 1.0)
    if wet and waterZ and waterZ >= z - 1.0 then return true, nil end
    local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 1.0, false)
    if found and math.abs(groundZ - z) < GROUND_SNAP_MAX then return true, groundZ end
    return false, nil
end

--- The player's game-wide rules: no wanted level, no AI police or emergency dispatch, PvP on (FiveM turns friendly
--- fire off by default). Set at each spawn, and after a death, which resurrects the player and never fires
--- 'spawned': cheap to say again in case a resurrect put any of them back.
local function worldRules()
    ClearPlayerWantedLevel(PlayerId())
    SetMaxWantedLevel(0)
    for i = 1, 15 do
        EnableDispatchService(i, false)
    end
    NetworkSetFriendlyFireOption(true)
end
AddEventHandler('whip_core:player:revived', worldRules)

--- Spawn the player at the given position (used after character select)
--- Health/armour are applied by the Stats system via statUpdate events — not here.
---@param pos table  {x, y, z, w}
local function SpawnPlayer(pos)
    -- + 0.0 on every one: a saved position arrives as JSON (a z of 54.0 comes back the integer 54),
    -- and natives read an integer in a float slot as raw bits (1 becomes 1.4e-45).
    local x = (pos.x or Config.DefaultSpawn.x) + 0.0
    local y = (pos.y or Config.DefaultSpawn.y) + 0.0
    local z = (pos.z or Config.DefaultSpawn.z) + 0.0
    local heading = (pos.w or Config.DefaultSpawn.w) + 0.0

    -- Normally already black (CharSelect.BeginLoad fades out on confirm). A backstop for paths that
    -- reach here without the character screen (respawn, admin teleport).
    if not IsScreenFadedOut() then
        DoScreenFadeOut(0)
    end

    RequestCollisionAtCoord(x, y, z)

    local ped = PlayerPedId()

    -- Frozen while placing: nothing may move under its own weight until the ground below it is real.
    PedHold.set('spawn', { frozen = true })
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
    SetEntityHeading(ped, heading)

    -- The scene round the spot, not just its ground (see WORLD_WAIT_MAX_MS).
    local scene = NewLoadSceneStartSphere(x, y, z, SCENE_RADIUS, 0)

    -- After the teleport: HasCollisionLoadedAroundEntity answers about where the streamer thinks the
    -- entity is, which for a frame or two is still the place we came FROM.
    Wait(100)

    local start = GetGameTimer()
    while GetGameTimer() - start < WORLD_WAIT_MAX_MS do
        RequestCollisionAtCoord(x, y, z)
        if HasCollisionLoadedAroundEntity(ped) and (not scene or IsNewLoadSceneLoaded()) then break end
        Wait(50)
    end

    -- Then something to stand on: a floor that streamed in after the ground has had its moment.
    local floorBy = GetGameTimer() + FLOOR_WAIT_MS
    local onFloor, groundZ = floorAt(x, y, z)
    while not onFloor and GetGameTimer() < floorBy do
        Wait(50)
        RequestCollisionAtCoord(x, y, z)
        onFloor, groundZ = floorAt(x, y, z)
    end
    if scene then NewLoadSceneStop() end
    if not onFloor then
        print(('[whip_core:spawn] nothing to stand on at %.1f, %.1f, %.1f after %.1f s: let go anyway'):format(
            x, y, z, (GetGameTimer() - start) / 1000))
    end

    -- On the floor rather than a few centimetres above it (a visible drop). From a metre up, so it
    -- finds the floor they stand ON; the distance guard keeps a deliberately elevated spawn's height.
    if groundZ then
        z = groundZ + 0.0
        SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
    end

    -- Down, and shown: character select's hide is let go here too, the backstop for any path that did
    -- not close it (client/ped_hold.lua — an /w Invisible admin stays hidden).
    PedHold.release('spawn')
    PedHold.release('charselect')

    -- And let them come to rest before anyone sees them (for spawns the snap declined to touch).
    -- One frame first: a ped unfrozen this instant would pass a stillness test it has not earned.
    Wait(0)
    local settling = 0
    while settling < SETTLE_MAX_MS do
        if not IsPedFalling(ped) and GetEntitySpeed(ped) < 0.1 then break end
        Wait(16)
        settling = settling + 16
    end

    worldRules()
    SetCanAttackFriendly(ped, true, true)

    -- No fade in here: the load sequence in client/player.lua raises it once the appearance and
    -- stats have finished too.
    WhipEmit('whip_core:player:spawned', {})
end

--- Spawn and settle, without touching the fade.
---
--- Global so the load sequence can CALL it and know when it has finished (TriggerEvent returns the
--- moment a handler yields).
---@param data table  the serialized player from playerLoaded
---@param posOverride vector4|table|nil  somewhere other than the character's own
---        position — the creator puts a brand new character on its own mark first,
---        and only sends them to the spawn point once they are finished.
function SpawnCharacterAt(data, posOverride)
    local pos = posOverride or (data and data.position) or {
        x = Config.DefaultSpawn.x,
        y = Config.DefaultSpawn.y,
        z = Config.DefaultSpawn.z,
        w = Config.DefaultSpawn.w,
    }

    SpawnPlayer(pos)
    hasSpawnedInitial = true

    -- The camera's room: spawning straight into a property's room, through no doorway, leaves the
    -- game believing the camera is outside (the interior culled). See client/viewport_room.lua; it
    -- waits for the gameplay camera, then settles its room.
    ViewportRoom.settle()

    -- Death and respawn are client/death.lua's; CompleteJoinSpawn has no respawn behaviour.
end

-- ============================================
-- Listen for player loaded → spawn at character position
-- ============================================
--
-- Kept for anything outside whip_core that fires it. The normal character load does NOT come
-- through here any more — client/player.lua calls SpawnCharacterAt directly so it can wait.

RegisterNetEvent('whip_core:client:spawned:ready', function(data)
    if not data then return end
    SpawnCharacterAt(data)
end)

-- ============================================
-- The join spawn, then character select
-- ============================================

--- Complete FiveM's join handshake and dismiss the loading screen (what spawnmanager would do;
--- SpawnCharacterAt above owns the real work). Four natives and an event:
---
---     NetworkResurrectLocalPlayer   the handshake itself — without it the client never finishes
---                                   joining and sits on the camera reading "awaiting scripts"
---     ClearPedTasksImmediately      drop whatever the join left the ped doing
---     ShutdownLoadingScreen         dismiss whip_loadingscreen
---     TriggerEvent('playerSpawned') two listeners: below, and ApplyWeaponLock in inventory.lua
---
--- The loading screen covers the join, and the picture goes black UNDER it before it is dismissed (see
--- the end), so the spawn point is never on screen.
local function CompleteJoinSpawn()
    local sp = Config.DefaultSpawn or vector4(-360.96, 51.44, 54.43, 177.83)

    -- + 0.0, as SpawnPlayer: natives read an integer in a float slot as raw bits.
    local x, y, z = sp.x + 0.0, sp.y + 0.0, sp.z + 0.0
    local heading = (sp.w or 0.0) + 0.0

    local playerId = PlayerId()
    local ped      = PlayerPedId()

    -- Hidden, frozen and invincible while it lands in terrain that has not streamed.
    SetPlayerControl(playerId, false, 0)
    PedHold.set('joinSpawn', { hidden = true, noCollision = true, frozen = true, invincible = true })

    RequestCollisionAtCoord(x, y, z)
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)

    -- The handshake: without it the client never finishes joining ("awaiting scripts").
    ---@diagnostic disable-next-line: param-type-mismatch, redundant-parameter -- as it always went; the natives' typing has fewer parameters than the game reads
    NetworkResurrectLocalPlayer(x, y, z, heading, true, true, false)
    PedHold.reapply()   -- it can hand back a new ped, which starts with none of the holds
    ClearPedTasksImmediately(ped)

    -- Bounded, because a client that cannot stream this spot must still finish joining — being
    -- somewhere without collision is recoverable, being stuck on the join camera is not.
    local deadline = GetGameTimer() + 5000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < deadline do
        Wait(0)
    end

    -- Re-read the handle: NetworkResurrectLocalPlayer can hand back a different ped.
    ped = PlayerPedId()

    SetPlayerControl(playerId, true, 0)
    PedHold.release('joinSpawn')

    -- Black under the loading screen first, and only then the loading screen away. DoScreenFadeOut(0)
    -- is not black in the frame it is called, so fading in the same frame the loading screen went (as
    -- this did, in the playerSpawned handler) put one frame of the spawn point on screen: the flash
    -- Josh saw on joining. Waits for the fade to report black, and one frame more for it to be drawn;
    -- bounded, so a fade that never reports still finishes the join.
    DoScreenFadeOut(0)
    local frames = 0
    while not IsScreenFadedOut() and frames < 30 do
        Wait(0); frames = frames + 1
    end
    Wait(0)

    -- The handler below also fades as its first statement (for a restart, where no loading screen
    -- covers anything); here the picture is black already. TriggerEvent is synchronous for local handlers.
    ShutdownLoadingScreen()
    TriggerEvent('playerSpawned', { x = x, y = y, z = z, heading = heading })

    -- After the event: its handler has taken the picture to black by now (its first statement).
    joinSpawnDone = true
end

CreateThread(function()
    -- This always runs, on a fresh join and on a restart alike: do not guard it with
    -- NetworkIsSessionStarted (the session can already be up on a real join).
    --
    -- A restart landing at DefaultSpawn is invisible: the handler below blacks the screen out, and
    -- the character the player then picks is placed by SpawnCharacterAt.

    -- No fade out here: the loading screen covers the join until it is shut down, and the
    -- playerSpawned handler below takes the picture to black in the same frame.

    CompleteJoinSpawn()
end)

--- Hide the world and ask the server for this account's characters.
local function ShowCharacterSelect()
    -- The menus' hold (client/ped_hold.lua): character select widens it, and closing it or the spawn
    -- lets it go.
    PedHold.set('charselect', { frozen = true, hidden = true })

    -- Only fade if there is a picture to lose (a restart, standing in the world). Through the
    -- curtain rather than DoScreenFadeOut, so the whole flow uses one blackout system, at
    -- CharSelect.TIMES.fadeOut's weight. GiveToGame leaves the game's fade holding the black, which
    -- CharSelect.Open takes over from.
    if not IsScreenFadedOut() then
        Curtain.GiveToGame(CharSelect.TIMES.fadeOut)
    end

    -- No preload here: CharSelect.Open walks the hero shots once the list has arrived (warming a
    -- shot and building its character are the same visit).
    -- Asked again if nothing answers (client/main.lua).
    RequestCharacterList()
end

--- The landing page, then the character screen. What both routes below do: a fresh join sometimes
--- takes the restart route (see isRestart), and a restart is a fresh login anyway.
--- The landing returns with the screen black; nothing when Config.Landing is switched off.
local function LandThenShowCharacterSelect()
    if Landing then Landing.Run() end
    ShowCharacterSelect()
end

AddEventHandler('playerSpawned', function()
    -- Black, first statement, before any other test. CompleteJoinSpawn has already taken the picture to
    -- black before the loading screen went; this holds it for any other caller of playerSpawned. It
    -- runs even when the early returns below apply.
    DoScreenFadeOut(0)

    -- A restart is the other route's job (see `isRestart` at the top of this file).
    if isRestart then return end

    -- Only do this on the very first spawn (not respawns)
    if hasSpawnedInitial then return end

    -- Player is fully spawned and has control
    Wait(1000)
    LandThenShowCharacterSelect()
end)

-- ============================================
-- Resource restart while already in the world
-- ============================================
--
-- Restarting whip_core logs the player out server-side, but nothing tells the client
-- (playerLogout is not fired). This is the second route back to the character screen.
-- CompleteJoinSpawn runs on a restart too, so playerSpawned fires as well: the two routes are kept
-- apart by `isRestart` (see its declaration).
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Not a restart: the playerSpawned route owns it.
    if not isRestart then return end

    CreateThread(function()
        -- Wait for the ready flag: ready.lua sets CoreReady once every client file has run.
        while not CoreReady do Wait(50) end

        -- And for the join spawn, for the landing page: until it finishes, the loading screen is
        -- still up on a fresh join, and its fade to black would put out the landing's shot.
        -- Bounded: a spawn that never finishes must not strand anybody (it takes 5 s at most).
        local deadline = GetGameTimer() + 10000
        while not joinSpawnDone and GetGameTimer() < deadline do Wait(50) end

        LandThenShowCharacterSelect()
    end)
end)
