-- ============================================
-- DEATH SYSTEM — client/death.lua
-- Handles death detection, ragdoll → anim transition,
-- control lockout, respawn countdown, revive, and
-- reconnect-while-dead.
-- Loads AFTER ui.lua.
-- ============================================

local isDead         = false
-- A respawn has begun: DoRespawn fades out, waits, parks the ped at 0,0,0 and waits again before the hospital,
-- and the server still counts the player dead until playerRespawned. Once it has begun it finishes; a medic's
-- revive arriving meanwhile stands down (the player is alive at the hospital either way).
local respawning     = false
-- A revive is bringing a dead ped back (ExitDeathState waits a moment for the resurrect): a second revive or a
-- respawn arriving meanwhile stands down.
local reviving       = false
local deathAnimDict  = 'dead'
local deathAnimName  = 'dead_a'
local RAGDOLL_SETTLE = 3000  -- ms to wait for ragdoll
local RESPAWN_HOLD   = 1500  -- ms to hold E to respawn

-- How long until a respawn is offered, and where: Config.RespawnTime and Config.RespawnLocations (config.lua), read
-- at each death so a change in /whip → Config counts from the next one.
local function respawnSeconds() return math.max(0, tonumber(Config.RespawnTime) or 10) end

-- A resource holding this death's respawn (the server's HoldRespawn): the words the death screen shows in place
-- of "Hold to respawn", or false. Told by the server as holds come and go; a death that ends clears it.
local respawnHold = false

--- One death screen message: to whip's own page (html/js/death.js), unless Config.DeathScreen is false, and always to
--- the resources on this game as the local event whip_core:death:screenChanged, so one can draw a death screen of
--- its own from the same fields:
---   { state = 'count', left, total }   { state = 'ready', progress, key }   { state = 'held', label }
---   { state = 'off' }                   { hidden }  (the hide key, H / Y)
--- whip still reads E (or A) held to respawn either way.
---@param msg table
local function deathScreenSay(msg)
    TriggerEvent('whip_core:death:screenChanged', msg)
    if Config.DeathScreen == false then return end
    msg.action = 'deathScreen'
    SendNUIMessage(msg)
end

-- The death screen's hide key: the screen (#death-screen, html/js/death.js) goes,
-- so the player can watch the world, and its key's hint stays bottom right, saying Show. H on a
-- keyboard (74, INPUT_VEH_HEADLIGHT) and Y on a pad (204, the frontend Y; never LB + Y, a combo).
-- Read through the death lock, as E is.
local SCREEN_KEY_KB  = 74
local SCREEN_KEY_PAD = 204

-- Forward-declared: EnterDeathState starts it and is defined above it. Assigned further down with
-- `function Name()`, which writes to this local; `local function Name()` there would shadow it, and
-- the death screen would never appear.
local RunRespawnFlow

--- The death lock: every control off bar the camera toggle (V), looking, chat (T), push to talk (N)
--- and E (held to respawn). Held from the moment a death begins (before the ragdoll settles) until
--- the player is alive again — ExitDeathState, DoRespawn, a logout. A newer death holds it again.
--- Its frame hook (deathFrame) reads the death screen's hide key, H / Y, through the lock.
local DEATH_BLOCK = { all = true, except = { 0, 1, 2, 245, 249, 38 } }

--- A hospital to wake up at: one of Config.RespawnLocations at random (Pillbox Hill when a server's list is empty).
local FALLBACK_HOSPITAL = vector4(360.83, -585.28, 28.83, 250.38)
local function pickRespawnLocation()
    local list = Config.RespawnLocations
    if type(list) ~= 'table' or #list == 0 then return FALLBACK_HOSPITAL end
    return list[math.random(#list)]
end

-- ============================================
-- Global Flag + Export
-- ============================================

-- Not `IsPlayerDead`: that is a real client native, and a global of the same name would read as
-- the (truthy) native FUNCTION if this file ever failed to load. The export below keeps the public
-- name IsPlayerDead.
PlayerIsDead = false

-- Every write to PlayerIsDead below is followed by WhipRefreshHudVisibility(): client/hud.lua is
-- pushed, not polled, so a write without it leaves the status HUD hidden after a respawn (or up
-- through a death). The function is change-gated, so a redundant call costs one comparison.

exports('IsPlayerDead', function()
    return isDead
end)

-- ============================================
-- Enter Death State
-- ============================================

-- Which death EnterDeathState is working on. See the checks after its waits.
local deathGen = 0

-- How the body is dead: 'seat' is GTA's own death slumped in a vehicle seat (the ped really is dead),
-- 'ground' is whip's (brought back, locked down, in the death pose). nil while changing from one to the
-- other. followSeat swaps them as the body is put into or taken out of vehicles.
local deathMode = nil

-- The death screen hidden by its key (SCREEN_KEY_*). Shown again at every new death.
local screenHidden = false

--- The death lock's frame hook (ControlBlocks' one loop, so no loop of its own): the hide key.
local function deathFrame()
    if not isDead then return end
    local pressed = WhipKeyPressed(SCREEN_KEY_KB, SCREEN_KEY_PAD)
    -- Not under another screen (the pause menu): its keys are its own.
    if not pressed or not IsGameInputFree() then return end
    screenHidden = not screenHidden
    deathScreenSay({ hidden = screenHidden })
end

--- Dead on the ground: brought back (a ped GTA has killed can't be held), locked down and laid in the death
--- pose where the body is, or at `at`. Answers false if the death ended or a respawn began meanwhile.
---@param gen number
---@param at vector3|nil
---@return boolean
local function layDown(gen, at)
    local function still() return isDead and deathGen == gen and not respawning end
    deathMode = nil
    local ped = PlayerPedId()
    local coords = at or GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    -- Hidden through the change. Ped holds (client/ped_hold.lua): 'deathHide' for the hide, 'death' for the
    -- lockdown (frozen, invincible), which nothing else's exit can cancel.
    PedHold.set('deathHide', { hidden = true })

    NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, heading, 1, false)
    Wait(100)
    ped = PlayerPedId()
    PedHold.reapply()   -- the resurrect can hand back a new ped, which starts with none of the holds
    if not still() then PedHold.release('deathHide') return false end

    -- Keep alive but fully locked down
    SetEntityHealth(ped, 200)
    SetPedArmour(ped, 0)
    PedHold.set('death', { invincible = true, frozen = true })
    SetEntityProofs(ped, true, true, true, true, true, true, true, true)
    SetPedSuffersCriticalHits(ped, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedCanRagdollFromPlayerImpact(ped, false)
    SetPedConfigFlag(ped, 179, true)   -- PedIgnoresAnimInterruptEvents
    SetPedConfigFlag(ped, 188, true)   -- DisableHurt (no flinch reactions)
    SetPedConfigFlag(ped, 122, true)   -- DisableMelee (remove from melee targeting)
    SetPedConfigFlag(ped, 161, true)   -- DontActivateRagdollFromMelee
    SetPedConfigFlag(ped, 2, true)     -- NoCriticalHits
    SetPedConfigFlag(ped, 404, false)  -- Suppress melee reactions when melee proof
    ClearPedTasksImmediately(ped)      -- also takes a ped still in a seat out of it
    if at then SetEntityCoordsNoOffset(ped, at.x, at.y, at.z, false, false, false) end

    local dictLoaded = LoadAnimDict(deathAnimDict)
    -- The exit undid the lockdown above itself; only the visibility is left to give back.
    if not still() then PedHold.release('deathHide') return false end

    if dictLoaded then
        TaskPlayAnim(ped, deathAnimDict, deathAnimName, 2.0, -2.0, -1, 1, 0, false, false, false)
    end
    RemoveAnimDict(deathAnimDict)
    deathMode = 'ground'

    -- Show in death pose
    Wait(200)
    PedHold.release('deathHide')
    return still()
end

--- Dead in a vehicle seat: GTA's own death, slumped where they sit. Whip's ground lockdown comes off, and a
--- ped brought back on the ground dies again in the seat. Still the one death: isDead stands, so nothing is
--- announced or reported twice.
---@param ped number
local function takeSeat(ped)
    PedHold.release('death')
    PedHold.release('deathHide')
    SetPedCanRagdoll(ped, true)   -- so the body falls if it is pulled out
    if not IsEntityDead(ped) then SetEntityHealth(ped, 0) end
    deathMode = 'seat'
end

--- A ped GTA has killed (dead in a seat) brought back where it is, for a death that ends without a revive
--- or respawn (a logout, whip_core stopping).
local function bringBackDeadPed()
    local ped = PlayerPedId()
    if not IsEntityDead(ped) then return end
    local c = GetEntityCoords(ped)
    NetworkResurrectLocalPlayer(c.x, c.y, c.z, GetEntityHeading(ped), 1, false)
    PedHold.reapply()
end

--- The seat a ped sits in, -1 for the driver, or nil.
---@return number|nil
local function seatOf(veh, ped)
    for seat = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
        if GetPedInVehicleSeat(veh, seat) == ped then return seat end
    end
    return nil
end

--- Out of the seat while dead (pulled out, the vehicle gone): the body falls, comes to rest (up to 3 s),
--- then lies as on the ground. Put into a seat again meanwhile: dead in that one instead.
local LEAVE_SETTLE_MS = 3000
local function leaveSeat(gen)
    deathMode = nil
    local deadline = GetGameTimer() + LEAVE_SETTLE_MS
    while true do
        Wait(250)
        if not (isDead and deathGen == gen) or respawning then return end
        local ped = PlayerPedId()
        if IsPedInAnyVehicle(ped, false) then takeSeat(ped) return end
        local v = GetEntityVelocity(ped)
        if v.x * v.x + v.y * v.y + v.z * v.z < 0.01 or GetGameTimer() >= deadline then break end
    end
    layDown(gen)
end

--- For as long as this death lasts, follow the body into and out of vehicles, however many times: dead in a
--- seat is GTA's, dead anywhere else is whip's (deathMode). A respawn under way is left to DoRespawn.
local SEAT_CHECK_MS = 250
local function followSeat(gen)
    while isDead and deathGen == gen do
        if not respawning then
            local ped = PlayerPedId()
            local seated = IsPedInAnyVehicle(ped, false)
            if deathMode == 'seat' and not seated then
                leaveSeat(gen)
            elseif deathMode == 'ground' and seated then
                takeSeat(ped)
            end
        end
        Wait(SEAT_CHECK_MS)
    end
end

--- A dead player pulled out of a vehicle by someone (the escort's Pull from Vehicle): a dead ped takes no
--- task, so they are laid down beside their door instead.
function DeathPullFromSeat()
    if not isDead or respawning or deathMode ~= 'seat' then return false end
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return false end
    local seat = seatOf(veh, ped) or -1
    local side = (seat == -1 or seat % 2 == 1) and -1.6 or 1.6   -- driver's side for -1, 1, 3...
    local at = GetOffsetFromEntityInWorldCoords(veh, side, 0.0, 0.0)
    -- A standing ped's height above the ground, as the death pose expects.
    local found, groundZ = GetGroundZFor_3dCoord(at.x, at.y, at.z + 1.0, false)
    if found then at = vector3(at.x, at.y, groundZ + 1.0) end
    local gen = deathGen
    deathMode = nil   -- now, so followSeat doesn't start a second change before the thread runs
    CreateThread(function() layDown(gen, at) end)
    return true
end

---@param skipRagdoll boolean  True when there is no fall to watch: loaded in dead, or a respawn refused
---@param reason 'reconnected'|'respawnRefused'|nil  why it is not a fresh death
local function EnterDeathState(skipRagdoll, reason)
    -- Already dead is not a new death: the reconnect-while-dead path waits 2000ms after playerLoaded,
    -- and the detection poll can fire first inside that window. This function starts the death
    -- screen's threads, so a second entry would run two countdowns.
    if isDead then return end

    isDead = true
    PlayerIsDead = true

    -- Still this death? The waits below add up to seconds, and a revive, a respawn or a /logout can
    -- end the death inside them; the lockdown must not land after the exit has cleaned up.
    deathGen = deathGen + 1
    local gen = deathGen
    local function stillThisDeath() return isDead and deathGen == gen end

    -- The one place a death begins, so the one place it is announced (a local event). `reconnected`
    -- is true when the player loaded in already dead. `respawnRefused` is the same death back after
    -- the server refused a respawn (DoRespawn had already announced 'revived').
    WhipEmit('whip_core:player:died', {
        reconnected    = reason == 'reconnected',
        respawnRefused = reason == 'respawnRefused',
    })

    -- The control lock and the countdown start here, before the ragdoll wait: the lock holds the
    -- controls DURING the settle, and the countdown's clock starts the moment `isDead` flips.
    --
    -- The lock is the 'death' control block (DEATH_BLOCK), let go wherever the death ends
    -- (ExitDeathState, DoRespawn, a logout). The countdown is its own thread (this function keeps
    -- waiting), looping while THIS death lasts, not `isDead`: a revive and a new death inside one of
    -- its sleeps would otherwise leave two countdowns running.
    screenHidden = false
    ControlBlocks.hold('death', DEATH_BLOCK, deathFrame)
    CreateThread(function() RunRespawnFlow(gen) end)
    -- Guarded the same way ResetDamageModifiers is below, and for the same reason: this file must
    -- survive another one failing to load. A stuck HUD is a nuisance; a death sequence that throws
    -- half way through leaves the player ragdolled, invisible and unable to respawn.
    if WhipRefreshHudVisibility then WhipRefreshHudVisibility() end

    deathMode = nil

    if not skipRagdoll then
        Wait(RAGDOLL_SETTLE)
        if not stillThisDeath() then return end
    end

    -- In a vehicle, GTA's own death stands: slumped in the seat. Anywhere else, whip's on the ground.
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then
        takeSeat(ped)
    elseif not layDown(gen) then
        return
    end
    CreateThread(function() followSeat(gen) end)

    -- Fade back from black (dramatic wake-up effect)
    if not skipRagdoll then
        SendNUIMessage({ action = 'deathFadeIn' })
    end
end

-- ============================================
-- Exit Death State (Revive)
-- ============================================

local function ExitDeathState()
    if not isDead or respawning or reviving then return end

    -- This death is over from here. Every step of it still under way (the fall's wait, laying the body down,
    -- following it into seats, the re-freeze after a drop, the countdown) checks deathGen and stands down, so
    -- none of them lands on the living ped (a lockdown landing after the revive leaves the player invincible).
    deathGen = deathGen + 1
    deathMode = nil
    local gen = deathGen

    local ped = PlayerPedId()

    -- A ped GTA counts dead is brought back first, wherever it is: still falling (a revive in the first seconds,
    -- before layDown has brought it back), killed again where it lay, or slumped in a seat (put back in that seat
    -- if the resurrect took them out). Health alone on a dead ped can leave it standing but still dead to GTA,
    -- so it can't be hurt, and the server's copy still reads it dead.
    if IsEntityDead(ped) then
        local veh = GetVehiclePedIsIn(ped, false)
        local seat = veh ~= 0 and seatOf(veh, ped) or nil
        local c = GetEntityCoords(ped)
        reviving = true
        NetworkResurrectLocalPlayer(c.x, c.y, c.z, GetEntityHeading(ped), 1, false)
        Wait(100)
        reviving = false
        -- A logout meanwhile ended the death itself.
        if not isDead or deathGen ~= gen then return end
        ped = PlayerPedId()
        PedHold.reapply()
        if seat and DoesEntityExist(veh) and GetVehiclePedIsIn(ped, false) ~= veh and IsVehicleSeatFree(veh, seat) then
            SetPedIntoVehicle(ped, veh, seat)
        end
    end
    local seated = IsPedInAnyVehicle(ped, false)

    PedHold.release('death')
    PedHold.release('deathHide')
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)
    SetPedSuffersCriticalHits(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, false)
    SetPedCanRagdoll(ped, true)
    SetPedCanRagdollFromPlayerImpact(ped, true)
    SetPedConfigFlag(ped, 179, false)
    SetPedConfigFlag(ped, 188, false)
    SetPedConfigFlag(ped, 122, false)
    SetPedConfigFlag(ped, 161, false)
    SetPedConfigFlag(ped, 2, false)
    SetEntityHealth(ped, 200)
    SetPedArmour(ped, 0)

    -- Reset damage modifiers (effects may have been active before death)
    if ResetDamageModifiers then ResetDamageModifiers() end

    -- Stop the death anim, then brief ragdoll → engine plays natural get-up. Not in a seat: that would
    -- throw them out of it.
    if not seated then
        ClearPedTasksImmediately(ped)
        SetPedToRagdoll(ped, 300, 300, 0, false, false, false)
    end

    isDead = false
    PlayerIsDead = false
    ControlBlocks.release('death')
    -- See the contract note at the top of this file, and the guard reasoning at the first of
    -- these four call sites.
    if WhipRefreshHudVisibility then WhipRefreshHudVisibility() end
    SendNUIMessage({ action = 'deathHide' })   -- the blackout and the death screen
    TriggerEvent('whip_core:death:screenChanged', { state = 'off' })   -- and a resource's own (deathScreenSay)

    -- Brought back where they lay. DoRespawn announces the other way back.
    WhipEmit('whip_core:player:revived', { how = 'revived' })

    if HasAnimDictLoaded(deathAnimDict) then
        RemoveAnimDict(deathAnimDict)
    end
end

-- ============================================
-- Respawn (teleport to hospital)
-- ============================================

local function DoRespawn()
    if not isDead or respawning or reviving then return end
    respawning = true   -- see its note at the top; let go below, the moment the player is alive again
    -- This death's steps still under way stand down, as for a revive (ExitDeathState): with a short
    -- Config.RespawnTime the respawn can begin before the body has even been laid down.
    deathGen = deathGen + 1
    deathMode = nil

    local loc = pickRespawnLocation()

    -- Off whoever was carrying us FIRST: the escort re-attaches every frame, and
    -- would put the respawned ped straight back on the holder.
    if EscortReleaseSelf then EscortReleaseSelf() end

    -- Fade to black. The death screen fades with it: GTA's fade is drawn under the page.
    deathScreenSay({ state = 'off' })
    DoScreenFadeOut(500)
    Wait(600)

    local ped = PlayerPedId()
    -- Dead in a seat: brought back where they sit first, so the clear below takes a living ped out of it.
    if IsPedInAnyVehicle(ped, false) and IsEntityDead(ped) then
        local c = GetEntityCoords(ped)
        NetworkResurrectLocalPlayer(c.x, c.y, c.z, GetEntityHeading(ped), 1, false)
        Wait(100)
        ped = PlayerPedId()
        PedHold.reapply()
    end
    PedHold.release('death')
    PedHold.release('deathHide')
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)
    SetPedConfigFlag(ped, 179, false)
    SetPedConfigFlag(ped, 188, false)
    SetPedConfigFlag(ped, 122, false)
    SetPedConfigFlag(ped, 161, false)
    SetPedConfigFlag(ped, 2, false)
    SetPedCanRagdoll(ped, true)
    SetPedCanRagdollFromPlayerImpact(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, false)
    SetPedSuffersCriticalHits(ped, true)
    ClearPedTasksImmediately(ped)

    -- Teleport to 0,0,0 briefly (load target area)
    SetEntityCoordsNoOffset(ped, 0.0, 0.0, 0.0, false, false, false)
    Wait(100)

    -- Teleport to hospital
    SetEntityCoordsNoOffset(ped, loc.x, loc.y, loc.z, false, false, false)
    SetEntityHeading(ped, loc.w)

    -- Revive
    NetworkResurrectLocalPlayer(loc.x, loc.y, loc.z, loc.w, 1, false)
    Wait(100)
    ped = PlayerPedId()
    PedHold.reapply()   -- a new ped starts with none of the holds (an /w Invisible admin stays hidden)
    SetEntityHealth(ped, 200)
    SetPedArmour(ped, 0)
    ClearPedTasksImmediately(ped)
    -- Treated at the hospital, so cleaned up too (ped damage is synced, so everyone sees the wounds).
    -- A revive where they lay keeps them.
    ClearPedBloodDamage(ped)
    ResetPedVisibleDamage(ped)

    -- Re-disable GTA health regen (resets on death)
    SetPlayerHealthRechargeMultiplier(PlayerId(), 0.0)
    SetPlayerHealthRechargeLimit(PlayerId(), 0.0)

    -- Reset damage modifiers
    if ResetDamageModifiers then ResetDamageModifiers() end

    isDead = false
    respawning = false
    PlayerIsDead = false
    ControlBlocks.release('death')
    -- See the contract note at the top of this file, and the guard reasoning at the first of
    -- these four call sites.
    if WhipRefreshHudVisibility then WhipRefreshHudVisibility() end
    SendNUIMessage({ action = 'deathHide' })
    TriggerEvent('whip_core:death:screenChanged', { state = 'off' })

    -- Alive again, at a hospital. ExitDeathState announces a revive where they lay.
    WhipEmit('whip_core:player:revived', { how = 'respawned' })

    if HasAnimDictLoaded(deathAnimDict) then
        RemoveAnimDict(deathAnimDict)
    end

    -- Tell server we respawned
    TriggerServerEvent('whip_core:server:playerRespawned')

    -- Load collision + fade in
    RequestCollisionAtCoord(loc.x, loc.y, loc.z)
    local t = 0
    while not HasCollisionLoadedAroundEntity(ped) and t < 2000 do
        Wait(50)
        t = t + 50
    end
    Wait(500)
    DoScreenFadeIn(500)
end

-- ============================================
-- Death Detection
-- ============================================

--- Is the player dead right now, and if so, start the death sequence.
---
--- One function, two callers (the 200ms poll and the damage event below), so the two never disagree
--- about what counts as dead.
local function CheckForDeath()
    if not PlayerLoaded or isDead then return end

    local ped = PlayerPedId()
    if not IsEntityDead(ped) then return end

    -- Fade to black immediately on death
    SendNUIMessage({ action = 'deathFadeOut' })

    -- Get killing blow info from the damage tracker (client/stats.lua)
    local killingBlow = nil
    if GetLastDamageSource then
        local src, ts = GetLastDamageSource()
        -- Only use if the damage event was very recent (within 2s of death)
        if src and (GetGameTimer() - ts) < 2000 then
            killingBlow = src
        end
    end

    TriggerServerEvent('whip_core:server:playerDied', killingBlow)
    EnterDeathState(false)
end

--- How often to ask the game whether the player has died.
---
--- 200ms even though the event below usually gets there first: drowning, falling, fire and a script
--- writing health to zero may raise no damage event at all. (Once the event is confirmed on both
--- platforms, 500ms is safe: every case it misses is gradual.)
local DEATH_POLL_MS = 200

CreateThread(function()
    while true do
        Wait(DEATH_POLL_MS)
        CheckForDeath()
    end
end)

-- The damage event: a trigger to look, not a source of truth. CEventNetworkEntityDamage fires the
-- instant fatal damage lands (the poll can be a fifth of a second late), but it cannot replace the
-- poll, and its argument layout is undocumented (args[4] as "victim died" varies across builds).
-- So on any hint of a death it just asks CheckForDeath (the poll's own IsEntityDead test): a wrong
-- index costs performance at worst, never a false death.
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' then return end

    -- args[1] is the victim: anything that is not our own ped is one comparison.
    if args[1] ~= PlayerPedId() then return end

    -- args[4] is believed to be the victim-died flag. Treated as a hint only; see above.
    --
    -- Not `if not args[4]`: the flag is 1/0, and Lua says 0 is true, so that test would pass on
    -- every non-fatal hit.
    local died = args[4]
    if died == nil or died == false or died == 0 then return end

    -- Called synchronously, not in a CreateThread: deferred, the poll could run CheckForDeath in the
    -- gap and both would fire whip_core:server:playerDied. Run directly, the first yield inside
    -- EnterDeathState is below `isDead = true`, so whichever caller gets here first closes the door.
    CheckForDeath()
end)

-- ============================================
-- Respawn Countdown + Hold-E
-- Born on death (EnterDeathState starts it), not a
-- permanent thread polling a local.
-- ============================================

--- Run the death screen: count down, then hold E. Returns when the player respawns or revives.
---
--- Called from EnterDeathState, so it lives exactly as long as the death does.
---@param gen number  the death this flow belongs to (deathGen when it began)
function RunRespawnFlow(gen)
    local function mine() return isDead and deathGen == gen end
    local deathTime = GetGameTimer()
    local total = respawnSeconds()
    local respawnAvailableAt = deathTime + (total * 1000)

    -- Phase 1: Countdown. The page draws the death screen (#death-screen, html/js/death.js): "You are
    -- dead", the seconds left and a bar that empties, on a red band at the bottom. Its key names
    -- (E / A, H / Y) follow the device in the page's CSS, so nothing here sends one.
    while mine() and GetGameTimer() < respawnAvailableAt do
        local remaining = math.ceil((respawnAvailableAt - GetGameTimer()) / 1000)
        deathScreenSay({ state = 'count', left = remaining, total = total, hidden = screenHidden })
        Wait(1000)
    end

    -- Phase 2: Hold E to respawn
    if not mine() then return end

    local holdStart = nil
    local lastShown = -1
    local shownHold = nil
    while mine() do
        -- Held by a resource (the server's HoldRespawn): its words in place of the hold, and no respawn until
        -- the last hold goes. Looked at four times a second: there is no key to read meanwhile.
        while mine() and respawnHold do
            holdStart, lastShown = nil, -1
            if shownHold ~= respawnHold then
                shownHold = respawnHold
                deathScreenSay({ state = 'held', label = respawnHold })
            end
            Wait(250)
        end
        shownHold = nil
        if not mine() then break end

        local progress = 0
        if holdStart then
            local held = GetGameTimer() - holdStart
            progress = math.min(100, (held / RESPAWN_HOLD) * 100)
            if held >= RESPAWN_HOLD then
                DoRespawn()   -- takes the death screen down as it fades
                break
            end
        end

        -- The Interact key (E unless moved), or A on a pad (controller.lua): LB is the talk key there, and LB + A
        -- never counts.
        -- Not while the screen is hidden: nothing would show the hold filling. Its key (bottom right,
        -- "Show") brings it back first.
        if not screenHidden and WhipAcceptHeld() then
            if not holdStart then holdStart = GetGameTimer() end
        else
            holdStart = nil
        end

        -- Only on change, quantized to whole percent: progress is a constant 0 unless E is held. The
        -- input poll above still runs per frame; only the NUI message is deduped. `key`: the Interact key's name,
        -- the one held on a keyboard (E unless the player moved it); a pad's A is the page's own picture.
        local shown = math.floor(progress)
        if shown ~= lastShown then
            lastShown = shown
            deathScreenSay({ state = 'ready', progress = shown, key = Interactions.keyName() })
        end
        Wait(0)
    end
end

-- ============================================
-- Refreeze after escort drop (let gravity settle)
-- ============================================

function DeathRefreezeAfterDrop()
    if not isDead or respawning or reviving then return end
    -- This death only: a revive and a new death inside the waits below are not this one.
    local gen = deathGen
    local function still() return isDead and deathGen == gen end
    local ped = PlayerPedId()

    -- Temporarily allow physics: death's hold keeps the invincibility and lets go of the freeze.
    PedHold.set('death', { invincible = true })
    SetBlockingOfNonTemporaryEvents(ped, false)
    SetPedCanRagdoll(ped, true)
    SetPedConfigFlag(ped, 179, false)
    SetPedConfigFlag(ped, 188, false)

    CreateThread(function()
        Wait(2000) -- grace period for falling
        while still() do
            ped = PlayerPedId()
            -- Put in a seat ("Seat in vehicle" releases the escort, which starts this thread): followSeat
            -- has them from here, dead in the seat and back on the ground if they are taken out.
            if IsPedInAnyVehicle(ped, false) then return end
            local vel = GetEntityVelocity(ped)
            local speed = vel.x * vel.x + vel.y * vel.y + vel.z * vel.z
            if speed < 0.01 then
                -- Settled — reapply full death lockdown
                ClearPedTasksImmediately(ped)

                local loaded = LoadAnimDict(deathAnimDict, 3000)
                -- Revived while it loaded (it waits up to 3 s): the looped death pose would hold a living player down.
                if not still() then RemoveAnimDict(deathAnimDict) return end
                if loaded then
                    TaskPlayAnim(ped, deathAnimDict, deathAnimName, 2.0, -2.0, -1, 1, 0, false, false, false)
                end
                RemoveAnimDict(deathAnimDict)

                Wait(300)
                -- Revived inside the wait: nothing to lock down (a hold set now would outlive the death).
                if not still() then return end
                PedHold.set('death', { invincible = true, frozen = true })
                SetBlockingOfNonTemporaryEvents(ped, true)
                SetPedCanRagdoll(ped, false)
                SetPedCanRagdollFromPlayerImpact(ped, false)
                SetPedConfigFlag(ped, 179, true)
                SetPedConfigFlag(ped, 188, true)
                SetPedConfigFlag(ped, 122, true)
                SetPedConfigFlag(ped, 161, true)
                return
            end
            Wait(500)
        end
    end)
end

-- ============================================
-- Server → Client: Revive
-- ============================================

RegisterNetEvent('whip_core:client:revive', function()
    ExitDeathState()
end)

--- The server refused a respawn (too soon after the death it recorded), but DoRespawn had already
--- stood the player up at the hospital. Back into the death screen where they stand: the server still
--- counts from the original death, so the next countdown's respawn is accepted.
RegisterNetEvent('whip_core:client:respawnRefused', function()
    if not isDead then EnterDeathState(true, 'respawnRefused') end
end)

--- The server's word on this death's respawn holds (HoldRespawn): the words to show, or false when none is left.
--- The server sends false when the death ends too (alive again, a logout), so nothing here has to clear it.
RegisterNetEvent('whip_core:client:respawnHold', function(label)
    respawnHold = (type(label) == 'string' and label ~= '') and label or false
end)

-- ============================================
-- Reconnect While Dead
-- ============================================

--- Which character load this is: a logout moves it on, so a delayed "loaded in dead" from the one
--- before stands down.
local loadGen = 0

RegisterNetEvent('whip_core:client:playerLoaded', function(data)
    loadGen = loadGen + 1
    if data and data.isDead then
        local myLoad = loadGen
        CreateThread(function()
            Wait(2000)
            -- Not after a logout inside the 2 s (F8 `logout`, a satellite's LogoutPlayer): the next
            -- character would inherit the death screen.
            if loadGen ~= myLoad or not PlayerLoaded then return end
            EnterDeathState(true, 'reconnected')
        end)
    end
end)

-- ============================================
-- Cleanup on Logout
-- ============================================

RegisterNetEvent('whip_core:client:playerLogout', function()
    loadGen = loadGen + 1
    -- The black screen goes too, dead or not: a death fades the page to black and only fades back
    -- in at the end of EnterDeathState (which returns early once the death is over), so a logout in
    -- that window would leave it over character select.
    SendNUIMessage({ action = 'deathHide' })
    TriggerEvent('whip_core:death:screenChanged', { state = 'off' })
    if isDead then
        isDead = false
        PlayerIsDead = false
        ControlBlocks.release('death')
        -- See the contract note at the top of this file, and the guard reasoning at the first
        -- of these four call sites.
        if WhipRefreshHudVisibility then WhipRefreshHudVisibility() end
        bringBackDeadPed()   -- dead in a seat: the next character would start dead
        ClearPedTasksImmediately(PlayerPedId())
        -- Its own holds (client/ped_hold.lua). On a logout, the logout's 'charselect' hold keeps the
        -- ped frozen and hidden.
        PedHold.release('death')
        PedHold.release('deathHide')
    end
end)

-- ============================================
-- Resource Cleanup
-- ============================================

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if isDead then
        -- The death screen is whip_core's page, which goes with it.
        bringBackDeadPed()
        ClearPedTasksImmediately(PlayerPedId())
        -- Its own holds (client/ped_hold.lua). On a logout, the logout's 'charselect' hold keeps the
        -- ped frozen and hidden.
        PedHold.release('death')
        PedHold.release('deathHide')
    end
end)
