-- Character select: a hero shot (spot, camera, sky, pose) per character slot, with cards that travel between them.
-- Characters are built once when the screen opens and stay until it closes. They are frozen (no falling through
-- unstreamed world), have no collision, and are mission entities (the population manager leaves them be).
-- The local ped is parked in each shot so the game streams it. Travel happens behind client/curtain.lua's blackout.

CharSelect = {}

--- The screen's timings, in ms except markZ. The four fades come from Config.CharSelectFades.
---   slotCover/slotUncover  the blink between shots
---   fadeOut / fadeIn       to black before the screen is built; back up once a character stands in the world
---   arriveHold             black held after arriving, while the world finishes appearing
---   openHold               black held on the first showing, so the light settles after the camera cut
---   fadeOnPlay/fadeOnCreate to black after Play; after a new character's details
---   preload                longest wait for one shot's world to stream in
---   settleMin/settleMax    wait for a new character's pose to take hold before freezing
---   dressMax               longest wait for clothes to stream in
---   markZ                  added to a shot's pos.z: marks are captured about a metre above the floor
CharSelect.TIMES = {
    slotCover = 160, slotUncover = 200,
    fadeOut = 500, fadeIn = 800, arriveHold = 500, openHold = 1000,
    fadeOnPlay = 600, fadeOnCreate = 900,
    preload = 1200, settleMin = 100, settleMax = 600, dressMax = 4000,
    markZ = -1.0,
}
local T = CharSelect.TIMES
do
    local fades = Config.CharSelectFades
    if type(fades) == 'table' then
        for _, k in ipairs({ 'fadeOut', 'fadeIn', 'fadeOnPlay', 'fadeOnCreate' }) do
            local ms = tonumber(fades[k])
            if ms then T[k] = math.max(0, math.min(5000, math.floor(ms))) end
        end
    end
end

--- Sky for a shot that names none: a still, sunny morning.
local FALLBACK_LOOK = { weather = 'EXTRASUNNY', hour = 6, minute = 0, frozen = true, priority = 1000 }

local _active = false
local _slot = 0        -- which place is showing, 0 = none
local _places = 0      -- how many places the screen has: one per character a player may have
local _peds = {}       -- place index -> preview ped (all built at once)
local _marks = {}      -- place index -> { x, y, z, w } where that ped settled, not where config put them
local _chars = {}      -- place index -> character row
local _props = {}      -- place index -> { object } held by that place's character (an emote's props)
local _scenes = {}     -- shot index -> { object } the shot's own props (the scene), made once per shot
local _switching = false

-- The spawn picker (see "The spawn picker" below).
local _canPick = false -- the page has the map built and the picker loaded (spawnselCan)
local _pickHeard = false -- the page has answered spawnselCan since this character screen asked (yes or no)
local _pick = nil      -- the look up in progress: { index, charId, spawns, cam, rot, pan, phase, gen }
local MAP_WAIT_MS = 30000   -- the character screen waits this long at most for the map to say if it can
local _viaMap = false  -- a character is loading from the map: no black, the map hands over to the arrival

--- Which shot a place shows: its own, or one that exists. Shot 1 always exists. Answers the shot and its index.
---@param n number  place index
---@return table|nil shot, number|nil shotIndex
local function shotFor(n)
    local slots = (Config.CharSelect and Config.CharSelect.slots) or {}
    if type(slots[n]) == 'table' then return slots[n], n end
    local made = {}
    for i = 1, #slots do
        if type(slots[i]) == 'table' then made[#made + 1] = i end
    end
    if #made == 0 then return nil, nil end
    local i = made[((n - 1) % #made) + 1]
    return slots[i], i
end
CharSelect.shotFor = shotFor

--- Bumped when the scene opens, closes or is handed to a character load. A trip carries the generation it
--- started in and stands down when it no longer matches.
local _sceneGen = 0

-- Helpers (through client/streaming.lua's loaders)
local function loadModel(name)
    local hash = GetHashKey(name)
    if not IsModelValid(hash) then return nil end
    return LoadModel(hash)
end

local loadAnimDict = function(dict) return LoadAnimDict(dict) end

--- An emote by its command name ('smoke6'), from the emote list.
---@param cmd string
---@return table|nil
local function emoteByCmd(cmd)
    for _, e in ipairs(EmoteList and EmoteList.emotes or {}) do
        if e.cmd == cmd then return e end
    end
    return nil
end

--- Take away what a slot's character is holding.
---@param n number  slot index
local function deleteSlotProps(n)
    for _, obj in ipairs(_props[n] or {}) do
        if DoesEntityExist(obj) then DeleteEntity(obj) end
    end
    _props[n] = nil
end

--- Make a shot's scene props once: frozen, not networked, script-owned. They keep collision so a pose can lean
--- on a table. Built in the player's own bucket.
---@param shotIndex number
---@param shot table
local function ensureScene(shotIndex, shot)
    if _scenes[shotIndex] then return end
    local made = {}
    for _, p in ipairs(shot.props or {}) do
        local hash = loadModel(p.model)
        if hash then
            local obj = CreateObjectNoOffset(hash, p.x + 0.0, p.y + 0.0, p.z + 0.0, false, false, false)
            SetModelAsNoLongerNeeded(hash)
            if obj and obj ~= 0 then
                SetEntityRotation(obj, (p.rx or 0.0) + 0.0, (p.ry or 0.0) + 0.0, (p.rz or 0.0) + 0.0, 2, true)
                FreezeEntityPosition(obj, true)
                SetEntityAsMissionEntity(obj, true, true)
                made[#made + 1] = obj
            end
        end
    end
    _scenes[shotIndex] = made
end

local function deleteScenes()
    for i, list in pairs(_scenes) do
        for _, obj in ipairs(list) do
            if DoesEntityExist(obj) then
                SetEntityAsMissionEntity(obj, true, true)
                DeleteEntity(obj)
            end
        end
        _scenes[i] = nil
    end
end

--- Show only place n's character; the others are hidden, props and all.
---@param n number
local function showOnly(n)
    for i, ped in pairs(_peds) do
        if DoesEntityExist(ped) then SetEntityVisible(ped, i == n, false) end
    end
    for i, list in pairs(_props) do
        for _, obj in ipairs(list) do
            if DoesEntityExist(obj) then SetEntityVisible(obj, i == n, false) end
        end
    end
end

-- Scene

--- Park the local ped at a shot so the game streams it in.
---@param at table|vector4  where to stand
---@param timeoutMs number|nil  how long to wait for the world
local function parkLocalPed(at, timeoutMs)
    local ped = PlayerPedId()

    -- + 0.0: an integer in a float native slot is read as its bit pattern.
    local x, y, z = at.x + 0.0, at.y + 0.0, at.z + 0.0

    RequestCollisionAtCoord(x, y, z)
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
    PedHold.set('charselect', { frozen = true, hidden = true, invincible = true, noCollision = true })
    SetPedCanRagdoll(ped, false)

    -- Let the world stream in, or the character spawns into a void.
    local budget = timeoutMs or 4000
    local waited = 0
    while not HasCollisionLoadedAroundEntity(ped) and waited < budget do
        Wait(50); waited = waited + 50
    end
end

local function releaseLocalPed()
    PedHold.release('charselect')
    SetPedCanRagdoll(PlayerPedId(), true)
end

--- Wait (up to maxMs) for a character's clothes to stream in: SetPedComponentVariation only requests them, so
--- a character shown too soon swaps clothes on screen.
---@param ped number|nil  nil (an empty place) waits for nothing
---@param maxMs number
local function waitDressed(ped, maxMs)
    if not ped or not DoesEntityExist(ped) then return end
    local deadline = GetGameTimer() + maxMs
    while not HaveAllStreamingRequestsCompleted(ped) and GetGameTimer() < deadline do Wait(50) end
end

--- Put the character into their pose: a scenario, an animation, or an emote (`emote = 'smoke6'` plays what
--- /e smoke6 plays, props included, full body).
---@param p table  the ground-corrected mark, not slot.pos (see markFor)
---@return table props  what the character was given to hold (deleted with them)
local function poseSlotPed(ped, slot, p)
    local props = {}
    local emote = slot.emote and emoteByCmd(slot.emote)
    if slot.emote and not emote then
        print(('[whip_core:charselect] there is no emote "%s" (the name after /e)'):format(tostring(slot.emote)))
    end
    if emote then
        for _, prop in ipairs(emote.props or {}) do
            local hash = loadModel(prop.model)
            if hash then
                local c = GetEntityCoords(ped)
                local obj = CreateObject(hash, c.x, c.y, c.z - 5.0, false, false, false)
                SetModelAsNoLongerNeeded(hash)
                SetEntityCollision(obj, false, false)
                local o, r = prop.offset or {}, prop.rot or {}
                AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, prop.bone or 18905),
                    (o[1] or 0.0) + 0.0, (o[2] or 0.0) + 0.0, (o[3] or 0.0) + 0.0,
                    (r[1] or 0.0) + 0.0, (r[2] or 0.0) + 0.0, (r[3] or 0.0) + 0.0,
                    true, true, false, false, 1, true)
                props[#props + 1] = obj
            end
        end
        if emote.scenario then
            TaskStartScenarioAtPosition(ped, emote.scenario, p.x, p.y, p.z, p.w, -1, true, false)
            return props
        end
        if emote.dict and emote.anim and loadAnimDict(emote.dict) then
            -- Loop (1) or hold the last frame (2), as the emote does.
            local flag = (emote.loop and 1 or 0) + (emote.freeze and 2 or 0)
            TaskPlayAnim(ped, emote.dict, emote.anim, 8.0, -8.0, -1, flag, 0.0, false, false, false)
            RemoveAnimDict(emote.dict)
            return props
        end
    end

    if slot.anim and slot.anim.dict and slot.anim.clip then
        if loadAnimDict(slot.anim.dict) then
            -- Flag 1 = looping; no duration.
            TaskPlayAnim(ped, slot.anim.dict, slot.anim.clip, 8.0, -8.0, -1, 1, 0.0, false, false, false)
            RemoveAnimDict(slot.anim.dict)
            return props
        end
        print(('[whip_core:charselect] anim dict "%s" failed to load'):format(slot.anim.dict))
    end

    if slot.scenario then
        -- Snap into the pose (no enter animation), at the corrected z the ped was built at.
        TaskStartScenarioAtPosition(ped, slot.scenario, p.x, p.y, p.z, p.w, -1, true, false)
    end
    return props
end

--- Where a slot's character actually stands: the config mark corrected by CharSelect.TIMES.markZ.
---@param slot table
---@return table mark  { x, y, z, w }
local function markFor(slot)
    local p = slot.pos
    return {
        x = p.x + 0.0,
        y = p.y + 0.0,
        z = p.z + T.markZ,
        w = p.w + 0.0,
    }
end

--- Pose a ped as a shot poses its character, at `at` (a corrected mark; the shot's own by default). Answers
--- what it was given to hold, for the caller to delete.
---@param ped number
---@param shot table
---@param at table|nil
---@return table props
function CharSelect.poseShot(ped, shot, at)
    return poseSlotPed(ped, shot, at or markFor(shot))
end

--- Stand one character up in their shot, settled and frozen. Reads the character from _chars.
---@param slotIndex number
---@return number|nil ped
local function buildSlotPed(slotIndex)
    local slot = shotFor(slotIndex)
    local char = _chars[slotIndex]
    if not slot or not char then return nil end

    local appearance = char.appearance
    local modelName = (appearance and appearance.model)
        or (char.gender == 'female' and 'mp_f_freemode_01' or 'mp_m_freemode_01')

    local hash = loadModel(modelName)
    if not hash then
        print(('[whip_core:charselect] could not load model "%s" for slot %d'):format(modelName, slotIndex))
        return nil
    end

    -- Corrected once, used for both the spawn and the pose.
    local p = markFor(slot)
    local ped = CreatePed(4, hash, p.x, p.y, p.z, p.w, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(ped) then return nil end

    -- Scenery: no wandering, reacting or being shot.
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedDiesWhenInjured(ped, false)
    SetEntityCanBeDamaged(ped, false)
    SetPedDefaultComponentVariation(ped)

    if appearance then
        ApplyAppearance(ped, appearance)
    end

    -- A rebuilt character must not leave its old props behind.
    deleteSlotProps(slotIndex)
    _props[slotIndex] = poseSlotPed(ped, slot, p)

    -- Settle, then freeze. The minimum is needed (a one-frame-old ped is not yet in physics); the ceiling
    -- avoids freezing something mid-air.
    local minMs = T.settleMin
    Wait(minMs)

    local elapsed = 0
    local budget = T.settleMax - minMs
    while elapsed < budget do
        if not IsPedFalling(ped) and GetEntitySpeed(ped) < 0.05 then break end
        Wait(50); elapsed = elapsed + 50
    end

    -- Where they ended up is the mark from now on (see restoreSlotPed).
    local at = GetEntityCoords(ped)
    _marks[slotIndex] = { x = at.x, y = at.y, z = at.z, w = GetEntityHeading(ped) }

    -- Frozen so they do not fall through unstreamed world; the pose survives it.
    FreezeEntityPosition(ped, true)

    -- No collision: the engine pushes a frozen ped out of ground that streams back in.
    SetEntityCollision(ped, false, false)

    -- Script-owned, so the population manager keeps them.
    SetEntityAsMissionEntity(ped, true, true)

    return ped
end

--- Put a character back exactly where they settled.
local function restoreSlotPed(slotIndex, ped)
    local mark = _marks[slotIndex]
    if not mark then return end
    SetEntityCoordsNoOffset(ped, mark.x, mark.y, mark.z, false, false, false)
    SetEntityHeading(ped, mark.w)
end

--- Make sure slot n's character is standing in their shot. Builds one if missing (opening pass, or the engine
--- reclaimed the ped).
local function ensureSlotPed(n)
    local existing = _peds[n]
    if existing and DoesEntityExist(existing) then
        restoreSlotPed(n, existing)
        return existing
    end
    _peds[n] = buildSlotPed(n)
    return _peds[n]
end

local function deleteAllPeds()
    for i, ped in pairs(_peds) do
        if DoesEntityExist(ped) then
            -- Re-assert ownership: a mission entity is only deletable by the script.
            SetEntityAsMissionEntity(ped, true, true)
            DeleteEntity(ped)
        end
        _peds[i] = nil
        _marks[i] = nil
    end
    -- What they held, even when the character is gone.
    for i in pairs(_props) do deleteSlotProps(i) end
end

-- Building the whole scene, once

--- Walk every hero shot and stand its character up, before the screen is shown. Walks backwards so slot 1's
--- world is still streamed in at the end.
--- Call from a thread, screen already black, _chars filled, and only when no character is loaded (the
--- server saves a loaded character's position from their ped, PlayerRows.markPosition).
---@return boolean finished  false if the screen changed hands while this was walking
local function buildScene()
    if Config.CharSelect.preloadShots == false then return true end
    local myGen = _sceneGen

    -- One stop per shot: places sharing a shot (shotFor) are built in the same visit.
    local order, stops = {}, {}
    for n = 1, _places do
        local shot, si = shotFor(n)
        if shot then
            ---@cast si -nil
            if not stops[si] then
                stops[si] = { shot = shot, places = {} }
                order[#order + 1] = si
            end
            local list = stops[si].places
            list[#list + 1] = n
        end
    end

    for k = #order, 1, -1 do
        -- Every stop yields; if the screen changed hands, peds built now would never be deleted.
        if _sceneGen ~= myGen then return false end

        local stop = stops[order[k]]
        parkLocalPed(stop.shot.pos, T.preload)
        -- Built while the world is loaded around them.
        ensureScene(order[k], stop.shot)
        for _, n in ipairs(stop.places) do
            if _sceneGen ~= myGen then return false end
            ensureSlotPed(n)
        end
    end

    return _sceneGen == myGen
end

-- Travelling between shots

--- Go to a slot's hero shot: stream the world in, set the sky, point the camera. The order matters: the world
--- must be streamed before anything in it renders, and the curtain lifts only when all of it is true.
---@param n number slot index
---@param opening boolean|nil  the screen's first showing (Open): held a moment longer, and faded in, not blinked
function CharSelect.SelectSlot(n, opening)
    if not _active then return end
    if _switching then return end
    if n == _slot then return end

    if n < 1 or n > _places then return end
    local slot, shotIndex = shotFor(n)
    if not slot then return end
    ---@cast shotIndex -nil

    _switching = true

    CreateThread(function()
        local myGen = _sceneGen
        -- The screen can be taken away at every yield below.
        local function abandoned()
            if _sceneGen == myGen and _active then return false end
            _switching = false
            return true
        end

        Curtain.Cover(T.slotCover)
        if abandoned() then return end

        -- 1. Stand the player in the shot so the game loads it.
        parkLocalPed(slot.pos)
        if abandoned() then return end

        -- 2. This shot's sky and clock, as a layer so Close() lifts it cleanly.
        if WeatherLayer then
            WeatherLayer.set('charselect', slot.look or FALLBACK_LOOK)
        end

        -- 3. Confirm the character and the shot's props; show only this place's character.
        ensureScene(shotIndex, slot)
        ensureSlotPed(n)
        showOnly(n)
        if abandoned() then return end

        -- 4. The shot itself. transitionIn is 0 (curtain is down). exitKey is off: the default ends the
        --    camera on Escape, dropping the player into a frozen invisible ped.
        local cam = slot.camera
        Camera.Play({
            pos           = cam.pos,
            rot           = cam.rot,
            fov           = cam.fov,
            filter        = cam.filter,
            transitionIn  = 0,
            transitionOut = 0,
            canLook       = false,
            canMove       = false,
            exitKey       = false,
        }, GetCurrentResourceName())

        _slot = n

        -- 5. Wait for their clothes (waitDressed).
        waitDressed(_peds[n], T.dressMax)
        if abandoned() then return end

        -- 6. One frame for the camera to arrive. The first showing waits longer (the light settles after
        --    a cut) and fades in (fadeIn) rather than blinking.
        Wait(opening and T.openHold or 0)
        if abandoned() then return end

        Curtain.Uncover(opening and T.fadeIn or T.slotUncover)
        _switching = false
    end)
end

-- Open / Close

--- Show the screen, on slot 1. Yields: the scene is built before the cards appear.
---@param chars table[] character rows from the server, in order
---@param maxChars number
function CharSelect.Open(chars, maxChars)
    if _active then CharSelect.Close(true) end
    _sceneGen = _sceneGen + 1
    _active = true
    _slot = 0
    _switching = false
    _chars = {}

    -- A place per character the player may have, with its own shot or a borrowed one (shotFor).
    _places = math.max(1, math.min(30, tonumber(maxChars) or tonumber(Config.MaxCharacters) or 4))
    local limit = math.min(#chars, _places)
    for i = 1, limit do
        _chars[i] = chars[i]
    end

    DisplayRadar(false)

    -- TakeFromGame puts the curtain up behind the game's fade; black stays until SelectSlot has a shot.
    Curtain.TakeFromGame()

    -- Build the spawn picker's map behind the black (unless the welcome screen did): the page answers
    -- spawnselCan once it is built or known impossible.
    _pickHeard = false
    if Config.CharSelect.spawnPicker ~= false then SendNUIMessage({ action = 'spawnselWarm' }) end

    -- Slot 1's sky now, so the light settles during the build walk behind the black.
    local first = shotFor(1)
    if WeatherLayer and first then
        WeatherLayer.set('charselect', first.look or FALLBACK_LOOK)
    end

    -- Yields for seconds; a newer Open landing meanwhile owns the screen and this one stands down.
    if not buildScene() then return end

    -- The map comes before the cards: they come up once the page says whether the map is there
    -- (spawnselCan). A page that never answers is waited for MAP_WAIT_MS, then the screen opens anyway.
    if Config.CharSelect.spawnPicker ~= false and not _pickHeard then
        local gen, by = _sceneGen, GetGameTimer() + MAP_WAIT_MS
        while not _pickHeard and gen == _sceneGen and GetGameTimer() < by do Wait(50) end
        if gen ~= _sceneGen then return end
        if not _pickHeard then
            print(('[whip_core:charselect] the spawn picker\'s map gave no answer in %d s: the character screen opens without it')
                :format(MAP_WAIT_MS // 1000))
        end
    end

    -- An empty slot is still a card. Only what a card renders is sent (no appearance blobs or birth dates).
    local cards = {}
    for i = 1, _places do
        local c = _chars[i]
        cards[i] = {
            index      = i,
            occupied   = c ~= nil,
            firstName  = c and c.firstName or nil,
            lastName   = c and c.lastName or nil,
            cash       = c and c.cash or nil,
            lastPlayed = c and c.lastPlayed or nil,
        }
    end

    SendNUIMessage({
        action        = 'showCharacters',
        cards         = cards,
        characterCount = limit,
        maxCharacters = maxChars or Config.MaxCharacters,
    })
    Focus.take('charselect', { screen = true })

    CharSelect.SelectSlot(1, true)
end

--- Tear the scene down.
---@param keepFaded boolean|nil  true when a rebuild is about to happen
function CharSelect.Close(keepFaded)
    if not _active then return end
    _sceneGen = _sceneGen + 1
    _active = false
    _switching = false
    _slot = 0
    -- The look up's camera is the shot's (Camera.Stop takes it). A load from the map carries on (_viaMap).
    _pick = nil

    deleteAllPeds()
    deleteScenes()
    _chars = {}

    Camera.Stop()
    releaseLocalPed()
    -- Not DisplayRadar(true): client/hud.lua owns the radar.

    -- Hand the sky back: dropping the layer lets whatever was underneath resolve again.
    if WeatherLayer then
        WeatherLayer.set('charselect', nil)
    end

    if not keepFaded then
        Focus.release('charselect')
        SendNUIMessage({ action = 'hide' })
        Curtain.Uncover(0)
    end
end

function CharSelect.IsActive() return _active end

-- Confirming a character

local _loading = false

--- Back from black to the character screen: the black onto the curtain first, then lifted (fadeIn).
local function comeBack()
    Curtain.TakeFromGame()
    SendNUIMessage({ action = 'show' })
    Focus.take('charselect', { screen = true })
    Curtain.Uncover(T.fadeIn)
end

--- The server refused the load: go back at once rather than after the 15 s timeout. A fresh list that
--- follows rebuilds the screen through CharSelect.Open.
RegisterNetEvent('whip_core:client:loadRefused', function(_, listFollows)
    if not _loading then return end
    _loading = false
    -- From the map: black over it, the map away, then the same way back.
    if _viaMap then
        CharSelect.AbortMap(not listFollows)
        return
    end
    if not listFollows then comeBack() end
end)

--- The player picked a character or filled in the create form. Goes to black first; Curtain.GiveToGame hands
--- the black back to the game's fade.
---@param send fun()  what to ask the server, once the screen is genuinely black
---@param ms number    how long the curtain takes to fall
local function beginTransition(send, ms)
    if _loading then return end
    _loading = true

    -- Any journey in progress stands down here.
    _sceneGen = _sceneGen + 1

    -- Hand input back before the blackout so the cursor is gone first.
    Focus.release('charselect')

    CreateThread(function()
        -- Falls in view, then the game's fade holds the black so the page can be hidden.
        Curtain.GiveToGame(ms)
        SendNUIMessage({ action = 'hide' })

        send()

        -- Timeout: do not strand the player on black.
        local t = 0
        while _loading and t < 15000 do Wait(500); t = t + 500 end
        if _loading then
            _loading = false
            print('[whip_core:charselect] no response from the server after 15s — fading back in')
            comeBack()
        end
    end)
end

---@param index number
function CharSelect.BeginLoad(index)
    -- The character by id, not card position (a second session could have moved it).
    local char = _chars[index]
    local charId = char and char.charId
    if not charId then return end
    if _pick then return end
    -- Where to arrive, on the map, when it can be (see "The spawn picker").
    if CharSelect.CanPick(char) then
        if not _switching then CharSelect.BeginPick(index) end
        return
    end
    -- Why there is no map this time, for F8.
    if Config.CharSelect.spawnPicker ~= false then
        print(('[whip_core:charselect] Play without the spawn picker: %s'):format(
            char.isDead and 'the character is dead (they come back where they fell)'
            or not _canPick and (_pickHeard and 'the map could not be built (F8 has why, from [pause map] or [spawn picker])'
                or 'the map gave no answer')
            or 'no places to pick from'))
    end
    beginTransition(function()
        TriggerServerEvent('whip_core:server:selectCharacter', charId)
    end, T.fadeOnPlay)
end

--- The player filled in the new-character form: the same treatment as picking one (black first).
---@param firstName string
---@param lastName string
---@param dateOfBirth string
---@param gender string
function CharSelect.BeginCreate(firstName, lastName, dateOfBirth, gender)
    beginTransition(function()
        TriggerServerEvent('whip_core:server:createCharacter', firstName, lastName, dateOfBirth, gender)
    end, T.fadeOnCreate)
end

local ENTER_WAIT_MS = 90000   -- from the welcome screen to standing in the world, at most

--- Enter a character with nobody at the game (export EnterCharacter, for tools and tests): passes the welcome
--- screen, picks the card and plays without the map, arriving where they left. Yields until loaded.
---@param opts table|nil  charId (number), or slot (1, 2 ...); the first card when neither is given
---@return boolean ok
---@return string|nil why
function CharSelect.Enter(opts)
    opts = type(opts) == 'table' and opts or {}
    if PlayerLoaded then return false, 'already in a character' end
    local deadline = GetGameTimer() + ENTER_WAIT_MS

    -- Welcome screen, then the character screen with cards up.
    while not (_active and _slot >= 1 and not _switching) do
        if GetGameTimer() > deadline then return false, 'the character screen never came up' end
        Landing.Continue()
        Wait(250)
    end

    ---@type integer|nil
    local index = math.tointeger(tonumber(opts.slot)) or 1
    if opts.charId ~= nil then
        index = nil
        for i, c in pairs(_chars) do
            if c.charId == tonumber(opts.charId) then index = i; break end
        end
        if not index then return false, 'no character with that id on this account' end
    end
    local char = _chars[index]
    if not char then return false, ('no character in slot %d'):format(index) end
    if _pick or _loading then return false, 'a character is already loading' end

    beginTransition(function()
        TriggerServerEvent('whip_core:server:selectCharacter', char.charId)
    end, T.fadeOnPlay)
    while not PlayerLoaded do
        if GetGameTimer() > deadline then return false, 'the character did not load in time' end
        Wait(250)
    end
    return true
end

exports('EnterCharacter', function(opts) return CharSelect.Enter(opts) end)

--- Called when the character is confirmed loaded, so the timeout above stands down.
function CharSelect.EndLoad()
    _loading = false
end

-- The spawn picker
-- Play on a character who has been in the world: the shot's camera looks up (CharSelect.PAN) while the page
-- (html/js/spawn-pick.js) brings a curtain and the 3D map over it. The player picks where to arrive from the
-- character's choices (server/spawn_choices.lua). Back (Escape, B) plays the look up backwards.
-- Once picked, the map waits over the place with the loading logo while the load runs behind it; the arrival
-- (client/arrival.lua, Arrival.fromMap) starts held on its first frame, the map lines up with it (spawnsel:go),
-- then fades out as the scene plays on (MapStarted).
-- Anything that ends a load from the map early puts the black over the map and sends it away (AbortMap).
-- A browser that cannot draw the map (spawnselCan) gets the fade, and so does a dead character.

--- The look up: how long it takes (ms) and how far it turns (degrees). The page's curtain follows the same
--- curve (easeInQuad) so the two are one motion.
CharSelect.PAN = { ms = 605, up = 70 }

local DONE_WAIT_MS = 1500   -- for the map to say it has gone (spawnsel:done) before going on without it
local LOAD_WAIT_MS = 15000  -- for the server to answer a load from the map, as beginTransition's
local FOLLOW_MAX_MS = 4000  -- the camera fed to the map after MapStarted: past this, the map is sent away

local _doneGen = 0          -- counts spawnsel:done, for whoever waits on one
local _goGen = 0            -- counts spawnsel:go

local function easeInQuad(t) return t * t end

--- Turn the shot's camera up (or back down) on the curtain's curve. Yields until done or another turn takes over.
local function lookUp(p, back)
    p.gen = p.gen + 1
    local gen, start = p.gen, GetGameTimer()
    while p.gen == gen and DoesCamExist(p.cam) do
        local t = math.min(1.0, (GetGameTimer() - start) / p.pan.ms)
        local e = easeInQuad(back and (1.0 - t) or t)
        SetCamRot(p.cam, p.pan.fromPitch + (p.pan.toPitch - p.pan.fromPitch) * e + 0.0, p.rot.y + 0.0, p.rot.z + 0.0, 2)
        if t >= 1.0 then return end
        Wait(0)
    end
end

--- Back to where the shot's camera looks.
local function lookLevel(p)
    p.gen = p.gen + 1
    if DoesCamExist(p.cam) then SetCamRot(p.cam, p.rot.x + 0.0, p.rot.y + 0.0, p.rot.z + 0.0, 2) end
end

--- Until the map says it has gone (spawnsel:done after `since`), or ms.
local function waitDone(since, ms)
    local deadline = GetGameTimer() + ms
    while _doneGen == since and GetGameTimer() < deadline do Wait(0) end
end

--- May this character choose where to arrive on the map?
---@param char table  a character row (Character.list): isDead, spawns
---@return boolean
function CharSelect.CanPick(char)
    return Config.CharSelect.spawnPicker ~= false and _canPick and _active and type(char) == 'table'
        and not char.isDead and type(char.spawns) == 'table' and #char.spawns > 0
end

--- Look up from slot `index`'s shot, and put the map over it with the character's choices.
---@param index number
function CharSelect.BeginPick(index)
    local char = _chars[index]
    if not char or _loading or _pick then return end
    -- The shot's camera (Camera.Play) is what looks up; without it there is nothing to look up from.
    local cam = GetRenderingCam()
    if not cam or cam == -1 or not DoesCamExist(cam) then return end
    local rot = GetCamRot(cam, 2)
    local spawns = char.spawns

    local p = {
        index = index, charId = char.charId, spawns = spawns, cam = cam, rot = rot, gen = 0, phase = 'open',
        pan = { ms = CharSelect.PAN.ms, fromPitch = rot.x, toPitch = math.min(89.0, rot.x + CharSelect.PAN.up),
                fov = GetCamFov(cam), ease = 'inQuad' },
    }
    _pick = p
    -- With the look up: the curtain is locked to it.
    SendNUIMessage({ action = 'spawnsel:open', spawns = spawns, defaultId = 'last', pan = p.pan })
    CreateThread(function() lookUp(p, false) end)
end

--- Is a character loading from the map? (client/player.lua asks: no black anywhere.)
function CharSelect.ViaMap() return _viaMap end

--- Where the game's camera is this frame, as the page takes it: GTA's rotation order 2, vertical fov.
local function renderedCam()
    local c, r = GetFinalRenderedCamCoord(), GetFinalRenderedCamRot(2)
    return { x = c.x, y = c.y, z = c.z, rotX = r.x, rotY = r.y, rotZ = r.z, fov = GetFinalRenderedCamFov() }
end

--- The arrival is held on its first frame behind the map, which is sent the camera to line up with
--- (Arrival.fromMap). The loading logo goes as it moves. Answers what to hand MapWent.
---@return number since
function CharSelect.MapReady()
    SendNUIMessage({ action = 'loadingLogo', on = false })
    local since = _goGen
    SendNUIMessage({ action = 'spawnsel:ready', cam = renderedCam() })
    return since
end

--- Has the map lined up with the camera since MapReady?
---@param since number
function CharSelect.MapWent(since) return _goGen ~= since end

--- The arrival plays on: the map fades, fed the camera every frame (spawnsel:cam) until it has gone or
--- FOLLOW_MAX_MS passes (then it is sent away). Answers what to hand WaitMapGone.
---@return number since
function CharSelect.MapStarted()
    _viaMap = false
    SendNUIMessage({ action = 'loadingLogo', on = false })
    local since = _doneGen
    SendNUIMessage({ action = 'spawnsel:started', cam = renderedCam() })
    CreateThread(function()
        local stopAt = GetGameTimer() + FOLLOW_MAX_MS
        while _doneGen == since and GetGameTimer() < stopAt do
            Wait(0)
            local cam = renderedCam()
            cam.action = 'spawnsel:cam'
            SendNUIMessage(cam)
        end
        if _doneGen == since then
            print('[whip_core:charselect] the map did not go after the arrival started: sent away')
            SendNUIMessage({ action = 'spawnsel:abort' })
        end
    end)
    return since
end

--- Until the map has gone (spawnsel:done since MapStarted's `since`), or ms. Yields.
function CharSelect.WaitMapGone(since, ms)
    waitDone(since, ms)
end

--- A load from the map that cannot finish: black over the map, map away, then back to the character screen
--- (`back`) or on with the plain fade load. Yields.
---@param back boolean|nil
function CharSelect.AbortMap(back)
    if not _viaMap and not _pick then return end
    local p = _pick
    _viaMap = false
    local since = _doneGen
    Curtain.Cover(0)
    SendNUIMessage({ action = 'spawnsel:abort' })
    waitDone(since, DONE_WAIT_MS)
    _pick = nil
    if back then
        if p then lookLevel(p) end
        comeBack()
    end
end

-- A logout while a load from the map runs (or a pick is open): the map goes at once, with no curtain or wait
-- (the logout's own black is already falling).
RegisterNetEvent('whip_core:client:playerLogout', function()
    if not _viaMap and not _pick then return end
    _viaMap, _pick = false, nil
    SendNUIMessage({ action = 'spawnsel:abort' })
end)

RegisterNUICallback('spawnselCan', function(data, cb)
    cb({ ok = true })
    _canPick = type(data) == 'table' and data.ok == true
    _pickHeard = true
end)

--- Escape or B on the list: the look up backwards, the curtain rising with it.
RegisterNUICallback('spawnsel:back', function(_, cb)
    cb({ ok = true })
    local p = _pick
    if not p or p.phase ~= 'open' then return end
    p.phase = 'closing'
    SendNUIMessage({ action = 'spawnsel:closing', pan = p.pan })
    CreateThread(function() lookUp(p, true) end)
end)

--- Where to arrive: only an id from the character's own list (the server checks again: server/spawn_choices.lua).
RegisterNUICallback('spawnsel:choose', function(data, cb)
    cb({ ok = true })
    local p = _pick
    if not p or p.phase ~= 'open' or _loading then return end
    local id = type(data) == 'table' and data.id or nil
    local known = false
    for _, s in ipairs(p.spawns) do
        if s.id == id then known = true; break end
    end
    if not known then return end

    p.phase = 'loading'
    _loading, _viaMap = true, true
    _sceneGen = _sceneGen + 1          -- any journey still in the air stands down
    Focus.release('charselect')        -- nothing more to press: the map waits for the game
    -- Loading logo while the map waits, off as the arrival starts (MapStarted); AbortMap's blackout takes it over.
    SendNUIMessage({ action = 'loadingLogo', on = true })
    TriggerServerEvent('whip_core:server:selectCharacter', p.charId, id)

    -- No answer: back to the character, as beginTransition's timeout.
    CreateThread(function()
        local t = 0
        while _loading and t < LOAD_WAIT_MS do Wait(500); t = t + 500 end
        if _loading then
            _loading = false
            print('[whip_core:charselect] no response from the server after 15s — back to the character screen')
            CharSelect.AbortMap(true)
        end
    end)
end)

--- The map has lined up with the held arrival's camera (MapReady).
RegisterNUICallback('spawnsel:go', function(_, cb)
    cb({ ok = true })
    _goGen = _goGen + 1
end)

--- The map has gone: faded off the arrival, rolled up after Back, or sent away (AbortMap). `failed` means the
--- map never came: this character, and every Play after, takes the plain fade load.
RegisterNUICallback('spawnsel:done', function(data, cb)
    cb({ ok = true })
    _doneGen = _doneGen + 1
    local p = _pick
    if not p then return end
    if p.phase == 'closing' then
        lookLevel(p)
        _pick = nil
    elseif p.phase == 'open' and type(data) == 'table' and data.failed then
        _canPick = false
        lookLevel(p)
        _pick = nil
        CharSelect.BeginLoad(p.index)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then CharSelect.Close(true) end
end)
