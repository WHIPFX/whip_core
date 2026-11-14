-- ============================================
-- Client Player State Cache — client/player.lua
-- ============================================

PlayerData = {}
PlayerLoaded = false

--- Update the local player data cache
---@param data table  Serialized player data from server
function SetPlayerData(data)
    PlayerData = data or {}
    PlayerLoaded = true
end

--- Clear player data on logout
function ClearPlayerData()
    PlayerData = {}
    PlayerLoaded = false
end

-- ============================================
-- Other players' names
-- ============================================
--
-- Names are not on the player statebags (those replicate to every client, so a cheat menu could
-- list every character on the server). This asks the server, which answers under
-- Config.ShowPlayerNames ('nearby' by default), and remembers the answer for a while: a label
-- function calls this every frame, and must not cost a round trip each time.

local NAME_KEEP_MS, REFUSED_KEEP_MS = 15000, 4000
local nameCache   = {}   -- [serverId] = { name = string|false, at = ms }
local namePending = {}   -- [serverId] = true while asking

local function lookUpName(sid)
    namePending[sid] = true
    local name = Callback('whip_core:playerName', sid)
    nameCache[sid] = { name = type(name) == 'string' and name or false, at = GetGameTimer() }
    namePending[sid] = nil
end

--- Another player's character name, by server id — the same name as the server export.
---
--- From a cache: the first ask for someone starts a lookup and answers nil, and a later ask (a label
--- asks every frame) has the name. `wait = true` waits for the answer instead, up to a few seconds.
--- nil also when the server will not say (Config.ShowPlayerNames: too far away, or 'never').
---@param serverId number
---@param wait boolean|nil
---@return string|nil
exports('GetPlayerFullName', function(serverId, wait)
    local sid = tonumber(serverId)
    if not sid then return nil end
    if sid == GetPlayerServerId(PlayerId()) then return PlayerData and PlayerData.fullName or nil end

    local entry = nameCache[sid]
    local fresh = entry and (GetGameTimer() - entry.at) < (entry.name and NAME_KEEP_MS or REFUSED_KEEP_MS)
    if not fresh then
        if not namePending[sid] then
            if wait then lookUpName(sid) else CreateThread(function() lookUpName(sid) end) end
        end
        if wait then
            local deadline = GetGameTimer() + 3000
            while namePending[sid] and GetGameTimer() < deadline do Wait(0) end
        end
        entry = nameCache[sid]
    end
    return entry and entry.name or nil
end)

-- ============================================
-- Server → Client Events
-- ============================================

--- The character load sequence: everything below runs behind a black screen, in order, and the
--- picture only comes back at the end.
---
--- Order matters:
---
---   Appearance BEFORE spawn: SetPlayerModel destroys and rebuilds the ped, taking its position
---   and heading with it.
---
---   Stats AFTER both: the model swap resets health and armour.
RegisterNetEvent('whip_core:client:playerLoaded', function(data)
    SetPlayerData(data)

    -- Picked on the spawn picker's map (client/charselect.lua): the map, not black, covers all of this, and it
    -- hands over to the arrival itself (Arrival.fromMap). A creator to finish or a death takes the old way, from
    -- whip's black over the map (CharSelect.AbortMap).
    local viaMap = CharSelect.ViaMap()

    CreateThread(function()
        -- A logout during the load's own waits (below) ends it there: no scene played into the character screen,
        -- no curtain lifted over it, no whip_core:player:loaded for a player who is not in the world.
        local gen = Arrival.generation()
        -- (The spawn picker's map is sent away by charselect.lua's own logout handler.)
        local function loggedOut()
            if Arrival.generation() == gen then return false end
            CleanScreen.release('load')
            -- A new character's creator look, set below before the creator opens: the creator's own logout handler
            -- does not see it then
            if WeatherLayer then WeatherLayer.set('creator', nil) end
            print('[whip_core] logged out during the load: it stops there')
            return true
        end

        -- 0. Nothing of whip's on screen until the character has arrived: the HUD and the minimap come
        --    up as the load starts (the stats, the HUD's defs), over the black, and showed there until the
        --    arrival scene put them away (Josh). CleanScreen holds them from here to the end of the
        --    arrival (step 7); the curtain and its loading logo are not hidden by it (css/ui.css).
        CleanScreen.hold('load')

        -- 1. Face and body. Blocks until the model is genuinely on.
        local creatorAppearance = ApplyLoadedAppearance(data)
        if loggedOut() then return end

        if viaMap and (creatorAppearance or data.isDead) then
            CharSelect.AbortMap(false)
            viaMap = false
        end

        -- 2. Put the finished ped where it belongs. Called directly, so this waits for it.
        --
        --    A brand new character does not go to the spawn point yet: they are built on the
        --    creator's own mark, in the private bucket they still hold from the character screen,
        --    and travel to the world when the creator closes (client/appearance.lua's FinishCreator).
        --
        --    Left sitting in a car that is still there (data.wakeIn, at whose position they were just
        --    put): back in their own seat while it is free and the car unlocked, else on foot beside it
        --    (a side a ray from the cabin reaches); beside it when it is a motorbike; or by
        --    a car of theirs that is near (data.nearCar). client/arrival.lua's Arrival.place.
        local place
        if creatorAppearance then
            local ccfg = Config.Creator or {}
            SpawnCharacterAt(data, ccfg.spawn)
            if WeatherLayer and ccfg.look then
                WeatherLayer.set('creator', ccfg.look)
            end
        else
            SpawnCharacterAt(data)
            -- Caught: a car that vanished between checks must not end the load (on foot where they stand)
            local ok, p = pcall(Arrival.place, data)
            if ok then place = p else print(('^1[whip_core:arrival] placing failed: %s^7'):format(tostring(p))) end
        end

        if loggedOut() then return end

        -- 3. Let the HUD catch up (normally instant; the timeout covers a lost packet).
        local waited = 0
        while not StatsSynced and waited < 3000 do
            Wait(50); waited = waited + 50
        end
        if loggedOut() then return end

        -- 4. The blackout moves to the curtain now, before any UI is raised: the game's screen fade
        --    hides the world but not NUI, which composites on top. With the curtain first, the
        --    creator comes up behind it, and one uncover reveals the world and the interface together.
        --    (From the map there is no black to move: the map is over everything.)
        if not viaMap then Curtain.TakeFromGame() end

        -- 5. A brand new character goes into the creator while still black, so it is already up
        --    when the picture returns instead of appearing over the world a moment later.
        if creatorAppearance then
            CleanScreen.release('load')   -- the creator is whip's own page: it must show
            OpenCreatorForNewCharacter(creatorAppearance)
            -- Hold the black until the creator's camera has finished arriving.
            -- It blends in from wherever the character screen left the gameplay
            -- camera, so raising the picture too early shows the shot still
            -- travelling to the ped — see Config.Creator.settleMs.
            Wait((Config.Creator or {}).settleMs or 1200)
        end

        -- 6. A beat before the picture comes back: the gameplay camera has just been teleported and
        --    the world around it is still arriving. Only on the plain load (the creator branch has
        --    already held for settleMs).
        if not creatorAppearance then
            Wait(CharSelect.TIMES.arriveHold)
        end
        if loggedOut() then return end

        -- 7. NOW it is loaded. The picture comes back on one of GTA's own switch scenes, played
        --    where they are (Config.ArrivalScenes, client/arrival.lua), which returns once the camera
        --    is back behind them. No scene fits (dead, in water, walls all round), or a new character
        --    in the creator: one lift, and the first thing anybody sees is the finished scene.
        --    Caught (Arrival.run): a scene that throws lets go of every hold it took, and the curtain lifts.
        --    From the map: the map turns and zooms to a camera straight down over them, and that camera drops into
        --    the scene (or behind them, when no scene fits) while the map fades off it.
        if viaMap then
            Arrival.fromMap(place, gen)
        else
            local played = not creatorAppearance and not data.isDead and Arrival.run(place, CharSelect.TIMES.fadeIn, gen)
            if not played and Arrival.generation() == gen then
                Curtain.Uncover(CharSelect.TIMES.fadeIn)
            end
        end
        if loggedOut() then return end
        -- The HUD and the minimap now, with the controls (step 0).
        CleanScreen.release('load')

        -- 8. And say so: a local event for other resources, fired once the character is really in
        --    the world and has the controls (whip_core:client:playerLoaded is the moment the load
        --    BEGINS). The same table the server's event carries.
        WhipEmit('whip_core:player:loaded', {
            source       = GetPlayerServerId(PlayerId()),
            charId       = data and data.charId,
            name         = data and data.fullName,
            -- The server's word, not "the creator opened": a creator re-opened for an unfinished
            -- character is not a new character (the welcome pack must not come again).
            newCharacter = data ~= nil and data.isNewCharacter == true,
            player       = data,
        })
    end)
end)

RegisterNetEvent('whip_core:client:playerLogout', function()
    -- The logout is starting: say so while the character it is about is still known.
    WhipEmit('whip_core:player:logout', { charId = PlayerData and PlayerData.charId })

    ClearPlayerData()

    -- Black first, then put them away. GiveToGame returns when the screen is covered, and leaves
    -- the game's fade holding the black for CharSelect.Open to take over from.
    Curtain.GiveToGame(CharSelect.TIMES.fadeOut)

    PedHold.set('charselect', { frozen = true, hidden = true })   -- the menus' hold (client/ped_hold.lua)

    -- Request character list again, and again if nothing answers (client/main.lua)
    RequestCharacterList()
end)

RegisterNetEvent('whip_core:client:updateCash', function(cash)
    if PlayerLoaded then
        PlayerData.cash = cash
    end
end)

--- One metadata key changed on the server (WhipPlayer:setMetadata).
RegisterNetEvent('whip_core:client:metadataChanged', function(key, value)
    if not PlayerLoaded or type(key) ~= 'string' then return end
    if type(PlayerData.metadata) ~= 'table' then PlayerData.metadata = {} end
    PlayerData.metadata[key] = value
end)

--- Renamed in the admin panel (server/character.lua Character.rename): the same character (charId), a new name.
--- The sheet's names change, and `whip_core:player:renamed` tells anything here that shows it.
RegisterNetEvent('whip_core:client:nameChanged', function(firstName, lastName)
    if not PlayerLoaded or type(firstName) ~= 'string' or type(lastName) ~= 'string' then return end
    PlayerData.firstName, PlayerData.lastName = firstName, lastName
    PlayerData.fullName = firstName .. ' ' .. lastName
    WhipEmit('whip_core:player:renamed', {
        charId = PlayerData.charId, firstName = firstName, lastName = lastName, name = PlayerData.fullName,
    })
end)

--- This player's account was given, or lost, a permission (server/permissions.lua). whip shows nothing: the local
--- event is for a resource that tells them, so none has to listen to whip's network message (audit 20, DX-10).
RegisterNetEvent('whip_core:client:permissionChanged', function(e)
    if type(e) ~= 'table' or type(e.permission) ~= 'string' then return end
    WhipEmit('whip_core:permission:changed', { permission = e.permission, granted = e.granted == true })
end)

-- ============================================
-- Client Exports
-- ============================================

--- The local player's sheet.
---
--- Live, not the login snapshot: metadata is pushed as it changes (metadataChanged above), and
--- isDead, health and armour are read from the live sources at call time. A copy, so a caller in
--- this resource cannot edit PlayerData by accident.
---@return table
local function playerData()
    if not PlayerLoaded then return {} end
    local out = {}
    for k, v in pairs(PlayerData) do out[k] = v end
    out.isDead = PlayerIsDead == true
    local health, armour = ClientStatValue('health'), ClientStatValue('armour')
    if health ~= nil then out.health = health end
    if armour ~= nil then out.armour = armour end
    return out
end
exports('GetPlayer', playerData)

exports('IsPlayerLoaded', function()
    return PlayerLoaded
end)

exports('GetCharId', function()
    return PlayerData.charId
end)
