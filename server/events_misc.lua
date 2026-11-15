-- ============================================
-- Miscellaneous Server Events & Exports
-- server/events_misc.lua
--
-- Contains:
--   - Death / revive (playerDied, interactionUsed, playerRespawned)
--   - Escort (escortPlayer, releaseEscort, seatInVehicle, pullFromVehicle)
--   - Appearance (SanitizeAppearance and OpenCharacterEditor exports, saveAppearance)
--   - Shop gameplay events (open, close, purchase, set price, stock)
--   - UI Library Tester gate
--   - Opening another player's inventory (open/close)
-- ============================================

-- Who a player is escorting: defined in the Escort System section below, and declared up here
-- because the death and respawn handlers above that section call it (a `local function` binds only
-- to code below it).
local getEscortTarget

-- ============================================
-- Death / Revive System
-- ============================================

-- Respawn holds (HoldRespawn): a resource keeps a dead player from respawning at a hospital while it means to come
-- for them (an EMS job: a medic on the way). Each hold is its resource's (a registry: a stopping resource lets go of
-- its own) and lasts this death only: it goes when the player is alive again, logs out or leaves. While any is on
-- them, their death screen shows the hold's words instead of "Hold to respawn", and playerRespawned is refused.
local respawnHolds = {}   -- [source] = { [regKey] = label }: the index the death screen and the respawn read

--- The words a held player's death screen shows: the first hold's, by key, so it does not flicker between two.
---@return string|nil
local function respawnHeldLabel(source)
    local holds = respawnHolds[source]
    if not holds then return nil end
    local firstKey
    for regKey in pairs(holds) do
        if not firstKey or regKey < firstKey then firstKey = regKey end
    end
    return firstKey and holds[firstKey] or nil
end

local function tellRespawnHold(source)
    TriggerClientEvent('whip_core:client:respawnHold', source, respawnHeldLabel(source) or false)
end

local respawnHoldReg = Registry.new('respawnHolds', {
    label  = 'respawn hold',
    scoped = true,
    onAdd = function(regKey, value, _, old)
        if old and old.source ~= value.source and respawnHolds[old.source] then
            respawnHolds[old.source][regKey] = nil
            if next(respawnHolds[old.source]) == nil then respawnHolds[old.source] = nil end
            tellRespawnHold(old.source)
        end
        respawnHolds[value.source] = respawnHolds[value.source] or {}
        respawnHolds[value.source][regKey] = value.label
        tellRespawnHold(value.source)
    end,
    onRemove = function(regKey, value)
        local holds = respawnHolds[value.source]
        if not holds then return end
        holds[regKey] = nil
        if next(holds) == nil then respawnHolds[value.source] = nil end
        tellRespawnHold(value.source)
    end,
})

--- Every hold on this player let go, whoever's: their death is over (alive, logged out, gone).
local function dropRespawnHolds(source)
    if not respawnHolds[source] then return end
    local mine = {}
    for regKey, value in pairs(respawnHoldReg.entries) do
        if value.source == source then mine[#mine + 1] = { owner = respawnHoldReg:ownerOf(regKey), id = value.id } end
    end
    for _, h in ipairs(mine) do respawnHoldReg:remove(h.owner, h.id) end
    respawnHolds[source] = nil
end

AddEventHandler('whip_core:player:logout', function(e) if type(e) == 'table' then dropRespawnHolds(e.source) end end)
AddEventHandler('playerDropped', function() dropRespawnHolds(source) end)

--- Hold a dead player's respawn: they stay where they lie, their death screen saying `label` (80 letters), until you
--- release it, they are revived, they log out, or your resource stops. `key` names your hold (the same again changes
--- its words). Only on a dead player: a hold is for this death.
---@return boolean ok, string|nil why
exports('HoldRespawn', function(source, key, label)
    local owner = Registry.caller()
    source = tonumber(source)
    local player = source and Players[source]
    if not player then return false, 'no such player' end
    if not player.isDead then return false, 'they are not dead' end
    local id = ('%d:%s'):format(source, tostring(key or 'hold'))
    local text = (type(label) == 'string' and label ~= '') and label:gsub('[\r\n\t]', ' '):sub(1, 80) or 'Help is on the way'
    local ok, why = respawnHoldReg:add(owner, id, { id = id, source = source, label = text })
    return ok, why --[[@as string|nil]]
end)

--- Let go of your hold `key` on this player (no key: every hold of yours on them). true when one went.
---@return boolean released
exports('ReleaseRespawn', function(source, key)
    local owner = Registry.caller()
    source = tonumber(source)
    if not source then return false end
    if key ~= nil then
        return (respawnHoldReg:remove(owner, ('%d:%s'):format(source, tostring(key)))) == true
    end
    local went = false
    for _, regKey in ipairs(respawnHoldReg:keysOf(owner)) do
        local value = respawnHoldReg:get(regKey)
        if value and value.source == source and respawnHoldReg:remove(owner, value.id) then went = true end
    end
    return went
end)

--- Is this player's respawn held? The words their screen shows, or nil.
exports('GetRespawnHold', function(source)
    return respawnHeldLabel(tonumber(source))
end)

--- Who the SERVER saw kill this ped, when it can say: 'Name (#12)' and their server id for a
--- player, else nil. A car that ran them over answers for its driver. The server's own record,
--- beside the client's claim.
---@param ped number
---@return string|nil label
---@return number|nil killerSource
local function serverKiller(ped)
    if not ped or ped == 0 then return nil end
    local ok, killer = pcall(GetPedSourceOfDeath, ped)
    if not ok or not killer or killer == 0 or not DoesEntityExist(killer) then return nil end
    if GetEntityType(killer) == 2 then killer = GetPedInVehicleSeat(killer, -1) end
    if not killer or killer == 0 then return nil end
    for src, p in pairs(Players) do
        if GetPlayerPed(src) == killer then return ('%s (#%d)'):format(p.fullName or '?', src), src end
    end
    return nil
end

--- Put a player into the dead state, from a VERIFIED signal.
---
--- Global rather than local because two files own a death signal: the playerDied event
--- below (a client report, verified against the ped before this runs) and reportVitals in
--- server/stats.lua (an accepted health of zero IS a death, whether or not the client ever
--- says the word). Both funnel here so the state change cannot drift between them.
---
--- `diedAt` is what playerRespawned gates on — see that handler for why the server keeps its
--- own clock instead of trusting the client to have waited.
---@param source number
---@param player table
---@param killingBlow string|nil
function MarkPlayerDead(source, player, killingBlow)
    if player.isDead then return end

    player.isDead = true
    player.diedAt = GetGameTimer()

    -- A holder who dies lets go, on the server's own word (not their client's).
    if getEscortTarget(source) then ReleaseEscortState(source) end

    -- One line: the killing blow is the client's own text, and the string sanitiser keeps line breaks
    -- (forged lines in the console and the txAdmin log).
    if type(killingBlow) == 'string' then killingBlow = killingBlow:gsub('[\r\n\t]', ' ') end

    -- Log the killing blow in the Stats change log, labelled as reported: it is the victim's own
    -- client's text ("Pistol by Bob (#12)").
    local hasKillingBlow = killingBlow and killingBlow ~= ''
    local deathLabel = hasKillingBlow and ('killed (reported): ' .. killingBlow) or 'death'
    Stats.set(source, 'health', 100, deathLabel)
    Stats.set(source, 'armour', 0, deathLabel)

    Sentinel.setPlayerKey(source, PLAYER_DEAD_KEY, true)

    -- The death row, here, so a death from either signal is on the timeline. What the server saw
    -- first, then what the client says.
    local byServer, killerSource = serverKiller(GetPlayerPed(source))
    local parts = {}
    if byServer then parts[#parts + 1] = 'killed by ' .. byServer end
    if hasKillingBlow then parts[#parts + 1] = 'reported: ' .. killingBlow end
    Log.write(player.charId, 'died', { detail = #parts > 0 and table.concat(parts, '; ') or nil })

    local deathMsg = hasKillingBlow
        and ('[whip_core] %s [%d] has died — reported: %s (charId: %d)'):format(player.fullName, source, killingBlow, player.charId)
        or  ('[whip_core] %s [%d] has died (charId: %d)'):format(player.fullName, source, player.charId)
    print(deathMsg)

    -- Told on the server too. `killer` is the server's own finding; `reported` is the victim's text,
    -- for display only. whip_core's own hooks first (Character.onLife 'died': the Systems' "goes
    -- down"), the public event after, as the other life moments do.
    local payload = {
        source   = source,
        charId   = player.charId,
        killer   = killerSource,
        reported = hasKillingBlow and killingBlow or nil,
    }
    Character.runHooks('died', payload)
    WhipEmit('whip_core:player:died', payload)
end

--- The other half: the ONE place a player stops being dead (revive, respawn, and the admin
--- commands), so diedAt and the rest are always cleared alike.
---@param source number
---@param player table
---@param why string  the Stats change-log label, e.g. 'revive', 'respawn', 'revive:admin'
function MarkPlayerAlive(source, player, why)
    local wasDead = player.isDead
    player.isDead = false
    player.diedAt = nil
    -- Moved on at every way back. A death still being confirmed against the ped (playerDied below, the vitals
    -- stream in server/stats.lua) stands down when it moves: the ped reads dead for a moment after a revive,
    -- until the client has brought it back, and that read would mark the revived player dead again.
    player.lifeGen = (player.lifeGen or 0) + 1
    dropRespawnHolds(source)   -- a hold is for one death

    -- Full health, no armour, a full breath (a drowned player comes back breathing: server/stats.lua's oxygen),
    -- and the spawn guard so the first vitals report cannot undo it.
    if Stats then
        Stats.set(source, 'health', 200, why)
        Stats.set(source, 'armour', 0, why)
        Stats.freshBreath(source, why)
        Stats.guardSpawn(source)
    end

    Sentinel.setPlayerKey(source, PLAYER_DEAD_KEY, false)

    -- The server's side of the client's revived event. `how` as the client says
    -- it; `reason` is the label above ('revive', 'respawn', 'revive:admin', 'revive:self').
    if wasDead then
        local payload = {
            source = source,
            charId = player.charId,
            how    = why == 'respawn' and 'respawned' or 'revived',
            reason = why,
        }
        Character.runHooks('revived', payload)   -- whip_core's own first, as 'died' above
        WhipEmit('whip_core:player:revived', payload)
    end
end

--- For tools and scripts: bring a downed player back where they lie, as /w Restore does (the server's record first,
--- then their game stands the ped up and ends the death screen). Full health, no armour.
---@param source number
---@param reason string|nil  for the Stats change log, after 'revive:' (default the resource that asked)
---@return boolean ok
---@return string|nil why  'Player not loaded', 'not down'
exports('RevivePlayer', function(source, reason)
    local src = tonumber(source)
    local player = src and Players[src]
    if not src or not player then return false, 'Player not loaded' end
    if not player.isDead then return false, 'not down' end
    MarkPlayerAlive(src, player, 'revive:' .. tostring(reason or GetInvokingResource() or 'script'))
    TriggerClientEvent('whip_core:client:revive', src)
    return true
end)

-- Client reports death (with optional killing blow context from damage tracker)
--
-- The report is a claim; the ped is the evidence (otherwise died-then-respawned is a free full
-- heal). A dead GTA ped reports health 0 (anything at or under 100 is dying), and a report about a
-- ped demonstrably alive changes nothing.
--
-- Replication lag: the client detects the death a beat before the server's copy of the ped catches
-- up, so a failed first read is read again, every quarter second for up to two seconds. A death
-- refused here is never learnt (the client stops reporting vitals once dead), and two seconds stays
-- inside the client's ragdoll settle (RAGDOLL_SETTLE, 3 s).
local DEATH_CONFIRM_MS = 2000

SecureEvent('whip_core:server:playerDied', {
    whileDead = true,   -- the death flow itself (dead players are refused by default; see secure.lua)
    rateLimit = 1000,
    params = {
        {'killingBlow', 'string', 120, ''},
    },
}, function(source, player, killingBlow)
    if player.isDead then return end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return end

    local life = player.lifeGen
    local deadline = GetGameTimer() + DEATH_CONFIRM_MS
    while GetEntityHealth(ped) > 100 do
        if GetGameTimer() >= deadline then
            RecordEventRejection('whip_core:server:playerDied', source,
                'reported dead but the ped is alive')
            return
        end
        Wait(250)
        -- Still the same session, not already dead by the vitals stream, and not revived meanwhile (MarkPlayerAlive)?
        if Players[source] ~= player or player.isDead or player.lifeGen ~= life then return end
        -- The handle, again: the first read may have raced a respawning ped.
        ped = GetPlayerPed(source)
        if not ped or ped == 0 then return end
    end

    -- The death row, the killer the server saw and the event are MarkPlayerDead's.
    MarkPlayerDead(source, player, killingBlow)
end)

--- Activity log: a player activated a 3D interaction point, a radial option, or an
--- aim-target option. Fired by the three client systems' ONE activation site each, so
--- every satellite's registrations (whip_dealership's Simon, whip_autos' radial entry)
--- are covered centrally with zero satellite edits. Client-supplied label — this is a
--- timeline note, not an authorization; anything the label CLAIMS was still separately
--- validated by whatever the activation actually did.
SecureEvent('whip_core:server:interactionUsed', {
    -- A log, not an action, so a downed player's use is written down too (points opted into
    -- `alive = false` fire this like any other).
    whileDead = true,
    rateLimit = 400,
    burst     = 3,
    params = {
        {'kind', 'enum', { 'interact', 'radial' }},
        {'label', 'string', 60},
    },
}, function(_, player, kind, label)
    Log.paced(player.charId, 'interaction', { detail = label .. ' · ' .. kind })
end)

-- An id is an ADDRESS: reject, never clamp (AsServerId, server/helpers.lua).
local asServerId = AsServerId

--- Where is this target player? For the `near` schemas below: the framework's own guard, with
--- Event Monitor logging and no early-return to slip past.
local function targetPosition(_, _, targetServerId)
    local id = asServerId(targetServerId)
    if not id then return nil end
    local ped = GetPlayerPed(id)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return c.x, c.y, c.z
end

-- Player respawned at hospital
--
-- Gated on the server's own clock: the countdown is Config.RespawnTime seconds on the client (client/death.lua), so
-- MarkPlayerDead stamps diedAt and this refuses anything faster. A second less on purpose: the gap absorbs the
-- round-trip and a slow frame. And refused while a resource holds the respawn (HoldRespawn, above).
local function respawnMinDeadMs()
    return math.max(0, math.floor((tonumber(Config.RespawnTime) or 10) * 1000) - 1000)
end

SecureEvent('whip_core:server:playerRespawned', {
    whileDead = true,   -- only a dead player can respawn
    rateLimit = 5000,
}, function(source, player)
    if not player.isDead then return end

    local deadFor = player.diedAt and (GetGameTimer() - player.diedAt) or nil
    local minMs = respawnMinDeadMs()
    local held = respawnHeldLabel(source)
    if held or not deadFor or deadFor < minMs then
        RecordEventRejection('whip_core:server:playerRespawned', source,
            held and ('respawn held: %s'):format(held)
            or deadFor and ('respawned after %dms, minimum is %dms'):format(deadFor, minMs)
            or 'respawned with no recorded death')
        -- And say so: the client stood up at the hospital before asking; told, it lies back down and
        -- counts again. A death with no clock starts one now, so the next count ends it.
        if not player.diedAt then player.diedAt = GetGameTimer() end
        TriggerClientEvent('whip_core:client:respawnRefused', source)
        return
    end

    -- A respawn ends an escort (or it would be a revive with no kit, right where they were held).
    -- Released here from the server's own record (the Sentinel ledger, not the bag); the client let
    -- go before it moved (EscortReleaseSelf).
    local holder = Sentinel.getTruth(source, PLAYER_ESCORTER_KEY)
    if holder then ReleaseEscortState(holder) end

    -- Respawns at full health, no armour.
    MarkPlayerAlive(source, player, 'respawn')
    print(('[whip_core] %s [%d] respawned at hospital'):format(player.fullName, source))
end)

-- ============================================
-- Escort System
-- ============================================

--- [holderSource] = the server id they are escorting: the server's O(1) answer (getEscortTarget
--- runs on every escort action and every playerDropped). The statebag stays the replicated truth for
--- clients; this is maintained at the same three write sites.
---
--- { sid, charId }: the CHARACTER as well as the source, since a source is reused by a relog.
local _escorting = {}

-- Helper: find who a player is escorting. Assigns the local declared at the top of this file.
function getEscortTarget(source)
    local e = _escorting[source]
    if not e then return nil end
    -- The target leaving clears THEIR state (player_lifecycle, which also calls ForgetEscortsOf);
    -- validated on read as well, so a stale entry answers nil and cleans itself up.
    local p = Players[e.sid]
    if not p or p.charId ~= e.charId then
        _escorting[source] = nil
        return nil
    end
    return e.sid
end

--- The escortee's session ended: nobody is holding them any more.
---@param targetSid number
function ForgetEscortsOf(targetSid)
    for holder, e in pairs(_escorting) do
        if e.sid == targetSid then _escorting[holder] = nil end
    end
end

--- Let go of whoever this player is escorting, and tell both clients. Global because a logout or a
--- disconnect releases too (server/player_lifecycle.lua).
---@param holderSource number
function ReleaseEscortState(holderSource)
    local targetSid = getEscortTarget(holderSource)
    _escorting[holderSource] = nil
    if targetSid then
        Sentinel.setPlayerKey(targetSid, PLAYER_ESCORTED_KEY, false)
        Sentinel.setPlayerKey(targetSid, PLAYER_ESCORTER_KEY, nil)
        TriggerClientEvent('whip_core:client:escortReleased', targetSid)
    end
    TriggerClientEvent('whip_core:client:escortReleased', holderSource)
end

--- Start holding: the state and both clients. The checks are the caller's.
local function beginEscort(holderSource, targetSid, target)
    Sentinel.setPlayerKey(targetSid, PLAYER_ESCORTED_KEY, true)
    Sentinel.setPlayerKey(targetSid, PLAYER_ESCORTER_KEY, holderSource)
    _escorting[holderSource] = { sid = targetSid, charId = target.charId }
    TriggerClientEvent('whip_core:client:escortStarted', holderSource, targetSid)
    TriggerClientEvent('whip_core:client:youAreEscorted', targetSid, holderSource)
end

--- An admin's Force escort (the object viewer, server/object_viewer.lua): from any distance, out of a vehicle if they
--- are in one, brought to the holder's side first. The holding rules still apply (nobody held twice, no loops).
---@return boolean ok
---@return string|nil why
function ForceEscort(holderSource, targetSid)
    if targetSid == holderSource then return false, 'You cannot escort yourself' end
    local target = Players[targetSid]
    if not target then return false, 'They are not loaded in' end
    if Sentinel.getTruth(targetSid, PLAYER_ESCORTED_KEY) then return false, 'They are already being escorted' end
    if getEscortTarget(holderSource) then return false, 'You are already escorting someone' end
    if Sentinel.getTruth(holderSource, PLAYER_ESCORTED_KEY) then return false, 'You are being escorted' end
    if getEscortTarget(targetSid) then return false, 'They are escorting someone' end
    -- (A character still in the creator's private bucket, or an Isolate world: a teleport does not cross buckets.)
    if GetPlayerRoutingBucket(targetSid) ~= GetPlayerRoutingBucket(holderSource) then
        return false, 'They are in another world (routing bucket)'
    end
    local tgtPed, myPed = GetPlayerPed(targetSid), GetPlayerPed(holderSource)
    if not tgtPed or tgtPed == 0 or not myPed or myPed == 0 then return false, 'They are not in the world' end
    if GetVehiclePedIsIn(tgtPed, false) ~= 0 then ClearPedTasksImmediately(tgtPed) end
    local at = GetEntityCoords(myPed)
    TriggerClientEvent('whip_core:client:pmTeleport', targetSid, at.x, at.y, at.z)
    beginEscort(holderSource, targetSid, target)
    return true
end

-- Distance stays hand-rolled in THIS handler (unlike revive/pull below): escort has its own
-- failure channel — escortFailed, which lets the client drop its optimistic escort state — and the
-- `near` schema's rejection would bypass it. The check itself cannot be skipped: it sits before any
-- state write, and every path around it fails.
--
-- The target stays 'any' + asServerId for the same reason: an 'id' param refuses a bad id at the
-- gate, before this handler runs — so escortFailed would never be sent and the client would be left
-- escorting nobody. Here a bad id is a `fail`, like every other refusal.
SecureEvent('whip_core:server:escortPlayer', {
    rateLimit = 1000,
    params = { {'targetServerId', 'any'} },
}, function(source, _, targetServerId)
    -- Tell the client to drop its optimistic state, and ANSWER the refusal: `return fail(..)` is
    -- `false, reason`, which whip shows the player and records.
    local function fail(reason)
        TriggerClientEvent('whip_core:client:escortFailed', source, reason)
        return false, reason
    end

    targetServerId = asServerId(targetServerId)
    if not targetServerId then return fail('Player not found') end
    if targetServerId == source then return fail('Cannot escort yourself') end

    local target = Players[targetServerId]
    if not target then return fail('Player not found') end

    -- Can't escort someone already escorted. The Sentinel ledger, not the bag: the bag is
    -- client-writable, so the target could spoof it.
    if Sentinel.getTruth(targetServerId, PLAYER_ESCORTED_KEY) then return fail('Player is already being escorted') end

    -- Can't escort if we're already escorting someone
    if getEscortTarget(source) then return fail('Already escorting someone') end

    -- Nor while being escorted, nor someone who is holding somebody (A holding B while B grabs A
    -- would be an attachment loop).
    if Sentinel.getTruth(source, PLAYER_ESCORTED_KEY) then return fail('You are being escorted') end
    if getEscortTarget(targetServerId) then return fail('They are escorting someone') end

    -- Target can't be in a vehicle
    local tgtPed = GetPlayerPed(targetServerId)
    if not tgtPed or tgtPed == 0 then return fail('Player not found') end
    if GetVehiclePedIsIn(tgtPed, false) ~= 0 then return fail('Player is in a vehicle') end

    -- Within 3m, through IsPlayerNear (which also keeps out a character still in the creator's
    -- private bucket).
    local tgtCoords = GetEntityCoords(tgtPed)
    if not IsPlayerNear(source, tgtCoords.x, tgtCoords.y, tgtCoords.z, 3.0) then return fail('Too far away') end

    beginEscort(source, targetServerId, target)
end)

SecureEvent('whip_core:server:releaseEscort', {
    whileDead = true,   -- dying lets go of whoever you were escorting
    rateLimit = 500,
    burst     = 3,      -- a refused release leaves the other player attached
}, function(source)
    ReleaseEscortState(source)
end)

SecureEvent('whip_core:server:seatInVehicle', {
    rateLimit = 1000,
    -- The player and the car are addresses ('id' rejects); seatIndex is a clamped small range,
    -- which is fine.
    params = { {'targetServerId', 'id'}, {'vehicleNetId', 'id', 1, 999999}, {'seatIndex', 'int', -1, 10} },
}, function(source, _, targetServerId, vehicleNetId, seatIndex)
    if targetServerId == source then return end

    -- Must be escorting this target. Ledger, not bag, as above.
    if Sentinel.getTruth(targetServerId, PLAYER_ESCORTER_KEY) ~= source then return end

    local target = Players[targetServerId]
    if not target then return end

    -- The car the holder is standing at, and a seat nobody is in: the net id and seat come from the
    -- holder's client, so the client option's checks are asked again here, where they count.
    local vehicle = NetworkGetEntityFromNetworkId(vehicleNetId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return end
    local holderPed = GetPlayerPed(source)
    if not holderPed or holderPed == 0
        or #(GetEntityCoords(holderPed) - GetEntityCoords(vehicle)) > 7.0 then return end
    if GetVehicleDoorLockStatus(vehicle) == 2 then return end
    if GetPedInVehicleSeat(vehicle, seatIndex) ~= 0 then return end

    -- Release escort FIRST
    Sentinel.setPlayerKey(targetServerId, PLAYER_ESCORTED_KEY, false)
    Sentinel.setPlayerKey(targetServerId, PLAYER_ESCORTER_KEY, nil)
    _escorting[source] = nil
    TriggerClientEvent('whip_core:client:escortReleased', targetServerId)
    TriggerClientEvent('whip_core:client:escortReleased', source)

    -- THEN seat in vehicle
    TriggerClientEvent('whip_core:client:seatInVehicle', targetServerId, vehicleNetId, seatIndex)
end)

SecureEvent('whip_core:server:pullFromVehicle', {
    rateLimit = 1000,
    params = { {'targetServerId', 'id'} },
    near = { at = targetPosition, range = 5.0, message = false },
}, function(source, _, targetServerId)
    if targetServerId == source then return end

    local target = Players[targetServerId]
    if not target then return end

    -- Can't pull if we're already escorting someone
    if getEscortTarget(source) then return end
    -- Nor while being escorted, nor someone holding somebody (as escortPlayer above).
    if Sentinel.getTruth(source, PLAYER_ESCORTED_KEY) then return false, 'You are being escorted' end
    if getEscortTarget(targetServerId) then return false, 'They are escorting someone' end

    -- Target must be in a vehicle — and not a locked one, the same rule seatInVehicle keeps.
    local tgtPed = GetPlayerPed(targetServerId)
    if not tgtPed or tgtPed == 0 then return end
    local tgtVehicle = GetVehiclePedIsIn(tgtPed, false)
    if tgtVehicle == 0 then return end
    if GetVehicleDoorLockStatus(tgtVehicle) == 2 then return false, 'The car is locked' end

    -- Pull from vehicle, then start the escort. The target is only TOLD it is escorted once the
    -- escort is recorded below, so a check that bails can't leave it frozen with nobody holding it.
    TriggerClientEvent('whip_core:client:pullFromVehicle', targetServerId, source)

    -- Set escort state after brief delay (let vehicle exit happen first)
    local targetCharId = target.charId
    SetTimeout(800, function()
        local t = Players[targetServerId]
        if not t or t.charId ~= targetCharId or not Players[source] then return end
        -- Asked again: in 800ms the holder may have started escorting somebody else, or somebody else
        -- taken this target.
        if getEscortTarget(source) then return end
        if Sentinel.getTruth(targetServerId, PLAYER_ESCORTED_KEY) then return end
        if Sentinel.getTruth(source, PLAYER_ESCORTED_KEY) or getEscortTarget(targetServerId) then return end
        Sentinel.setPlayerKey(targetServerId, PLAYER_ESCORTED_KEY, true)
        Sentinel.setPlayerKey(targetServerId, PLAYER_ESCORTER_KEY, source)
        _escorting[source] = { sid = targetServerId, charId = targetCharId }
        TriggerClientEvent('whip_core:client:escortStarted', source, targetServerId)
        TriggerClientEvent('whip_core:client:youAreEscorted', targetServerId, source)
    end)
end)


-- (Inventory, item-registration and config-read exports live in server/inventory.lua, with the
-- functions and tables they forward to.)




-- ============================================
-- Save Appearance (client → server)
-- ============================================

--- The appearance shape validator, on the Vehicles.sanitizeProperties pattern:
--- whitelist-copy into a NEW table (never mutate the input — the caller's table
--- may live on), REJECT structural wrongness, CLAMP mere out-of-range values, so
--- a modified client can't park arbitrary JSON in characters.metadata.
---
--- Numeric caps are deliberately generous where the real maximum lives client-
--- side (drawable counts vary per model/DLC and the natives no-op on invalid
--- ids anyway); they exist to bound the data, not to know the catalogue.

local APPEARANCE_MODELS = { ['mp_m_freemode_01'] = true, ['mp_f_freemode_01'] = true }

-- name → true when the overlay carries color/color2 (mirrors OVERLAY_COLOR_TYPE
-- in client/appearance.lua)
local APPEARANCE_OVERLAYS = {
    blemishes = false, beard = true, eyebrows = true, ageing = false,
    makeup = true, blush = true, complexion = false, sunDamage = false,
    lipstick = true, moles = false, chestHair = true,
}

local APPEARANCE_PROP_IDS = { ['0'] = true, ['1'] = true, ['2'] = true, ['6'] = true, ['7'] = true }

-- The most tattoos one character keeps: a bound on the data, like the ceilings below, not the game's
-- own limit: 40 of the longest names is about 3 KB of the save's 10 KB.
local APPEARANCE_TATTOO_MAX = 40

-- Every tattoo the editor can offer (shared/tattoo_list.lua), by 'collection/overlay' in lower case — the
-- game's hashes ignore case, so a name in any case is the same tattoo — to its proper names and the body
-- it is for. Unlike the clothing numbers this CAN be exact: a tattoo is a name, and the list is the names.
local APPEARANCE_TATTOOS = {}
for _, t in ipairs(TattooList.list) do
    local coll = TattooList.collections[t[1]].name
    APPEARANCE_TATTOOS[(coll .. '/' .. t[2]):lower()] = { collection = coll, overlay = t[2], body = t[4] }
end

-- Every hair fade the editor can offer (shared/hair_fades.lua), keyed the same way.
local APPEARANCE_FADES = {}
for _, f in ipairs(HairFades.list) do
    local coll = HairFades.collections[f[1]].name
    APPEARANCE_FADES[(coll .. '/' .. f[2]):lower()] = { collection = coll, overlay = f[2], body = f[3] }
end

-- `v ~= v` is the NaN test: msgpack happily carries NaN floats off the wire,
-- NaN sails through math.min/max comparisons, and json.encode chokes on it at
-- save time. It gets the default like any other non-answer.
local function clampInt(v, min, max, default)
    if type(v) ~= 'number' or v ~= v then return default end
    return math.max(min, math.min(max, math.floor(v)))
end

local function clampFloat(v, min, max, default)
    if type(v) ~= 'number' or v ~= v then return default end
    return math.max(min, math.min(max, v))
end

---@param appearance any  the client-sent table
---@return table|nil sanitized  nil when structurally invalid
---@return string|nil err
local function sanitizeAppearance(appearance)
    if type(appearance) ~= 'table' then return nil, 'not a table' end
    if not APPEARANCE_MODELS[appearance.model] then return nil, 'bad model' end

    local hb = appearance.headBlend
    if type(hb) ~= 'table' then return nil, 'missing headBlend' end

    local ff = appearance.faceFeatures
    if type(ff) ~= 'table' or #ff ~= 20 then return nil, 'faceFeatures must be 20 entries' end
    for i = 1, 20 do
        if type(ff[i]) ~= 'number' then return nil, 'faceFeatures must be numbers' end
    end

    if type(appearance.hair) ~= 'table' then return nil, 'missing hair' end
    if type(appearance.overlays) ~= 'table' then return nil, 'missing overlays' end
    if type(appearance.components) ~= 'table' then return nil, 'missing components' end
    if type(appearance.props) ~= 'table' then return nil, 'missing props' end
    -- Tattoos are the one optional part: an appearance saved before they existed has none.
    if appearance.tattoos ~= nil and type(appearance.tattoos) ~= 'table' then return nil, 'tattoos must be a list' end

    local out = {
        model = appearance.model,
        headBlend = {
            mom = clampInt(hb.mom, 0, 45, 0),
            dad = clampInt(hb.dad, 0, 45, 0),
            grandparent = clampInt(hb.grandparent, 0, 45, 0),
            faceWeight = clampFloat(hb.faceWeight, 0.0, 1.0, 0.5),
            skinWeight = clampFloat(hb.skinWeight, 0.0, 1.0, 0.5),
            thirdWeight = clampFloat(hb.thirdWeight, 0.0, 1.0, 0.0),
        },
        faceFeatures = {},
        eyeColor = clampInt(appearance.eyeColor, 0, 31, 0),
        hair = {
            -- 4095 for the same reason as the components below: a sanity bound, well clear of any DLC.
            style = clampInt(appearance.hair.style, 0, 4095, 0),
            texture = clampInt(appearance.hair.texture, 0, 127, 0),
            color = clampInt(appearance.hair.color, 0, 63, 0),
            highlight = clampInt(appearance.hair.highlight, 0, 63, 0),
        },
        overlays = {},
        components = {},
        props = {},
    }

    for i = 1, 20 do
        out.faceFeatures[i] = clampFloat(ff[i], -1.0, 1.0, 0.0)
    end

    for name, hasColor in pairs(APPEARANCE_OVERLAYS) do
        local ov = appearance.overlays[name]
        if type(ov) == 'table' then
            local entry = {
                type = clampInt(ov.type, 0, 255, 0),   -- 255 is the "cleared" sentinel
                opacity = clampFloat(ov.opacity, 0.0, 1.0, 0.0),
            }
            if hasColor then
                entry.color = clampInt(ov.color, 0, 63, 0)
                entry.color2 = clampInt(ov.color2, 0, 63, 0)
            end
            out.overlays[name] = entry
        end
    end

    -- components/props keep their STRING keys — the shape is a JSON round-trip
    -- contract with the metadata column and ApplyAppearance's tonumber() reads.
    --
    -- The ceiling is a sanity bound, not a validity check: which drawables exist depends on the model
    -- and the mounted clothing DLC (freemode tops already run past 600), and there is no ped here to
    -- ask. So it only stops an absurd payload, set well clear of anything real. The exact check is
    -- where a ped exists: ApplyAppearance in client/appearance.lua clamps against the model's counts.
    for i = 0, 11 do
        local comp = appearance.components[tostring(i)]
        if type(comp) == 'table' then
            out.components[tostring(i)] = {
                drawable = clampInt(comp.drawable, 0, 4095, 0),
                texture = clampInt(comp.texture, 0, 127, 0),
            }
        end
    end

    -- Props get the same treatment for the same reason.
    for key in pairs(APPEARANCE_PROP_IDS) do
        local prop = appearance.props[key]
        if type(prop) == 'table' then
            out.props[key] = {
                drawable = clampInt(prop.drawable, -1, 4095, -1),
                texture = clampInt(prop.texture, 0, 127, 0),
            }
        end
    end

    -- Tattoos, in the order they were put on (a later one draws over an earlier one where they
    -- overlap). Kept: a tattoo the list names, for this body, once, up to APPEARANCE_TATTOO_MAX — each
    -- written back with the list's own spelling. Anything else is dropped rather than refused, as an
    -- out-of-range number is clamped: one stale name must not cost the player the rest of their save.
    -- Left out of the save altogether when there are none.
    local body = (appearance.model == 'mp_f_freemode_01') and 'f' or 'm'
    if appearance.tattoos then
        local tattoos, seen = {}, {}
        for _, t in ipairs(appearance.tattoos) do
            if #tattoos >= APPEARANCE_TATTOO_MAX then break end
            if type(t) == 'table' and type(t.collection) == 'string' and type(t.overlay) == 'string'
                and #t.collection <= 64 and #t.overlay <= 64 then
                local key = (t.collection .. '/' .. t.overlay):lower()
                local known = APPEARANCE_TATTOOS[key]
                if known and known.body:find(body, 1, true) and not seen[key] then
                    seen[key] = true
                    tattoos[#tattoos + 1] = { collection = known.collection, overlay = known.overlay }
                end
            end
        end
        if #tattoos > 0 then out.tattoos = tattoos end
    end

    -- The hair fade, one at most: kept when the list names it for this body, in the list's spelling.
    -- Anything else is dropped, as a tattoo is. None: no key.
    local fade = appearance.hairFade
    if type(fade) == 'table' and type(fade.collection) == 'string' and type(fade.overlay) == 'string'
        and #fade.collection <= 64 and #fade.overlay <= 64 then
        local known = APPEARANCE_FADES[(fade.collection .. '/' .. fade.overlay):lower()]
        if known and known.body:find(body, 1, true) then
            out.hairFade = { collection = known.collection, overlay = known.overlay }
        end
    end

    return out, nil
end

-- The same rules for a look that is no character's: a lore character made in the character editor
-- (server/director/lore.lua).
SanitizeAppearanceData = sanitizeAppearance

-- Exported so whip_test can pin the validator's behavior (and a satellite
-- staging appearance data can pre-validate with the server's own rules).
--
-- Boolean first, because (nil, string) doesn't survive an export: a leading nil truncates the
-- tuple. The validator itself still answers (nil, err) to the in-process caller below.
---@param appearance table
---@return boolean ok
---@return table|string result  the sanitized appearance, or the reason it was refused
exports('SanitizeAppearance', function(appearance)
    local out, err = sanitizeAppearance(appearance)
    if not out then return false, err or 'invalid appearance' end
    return true, out
end)

--- Open a player's character editor on their own character, as /charedit does: Save keeps the new look, Cancel
--- puts the old one back. The OpenCharacterEditor export and the object viewer's Force open character editor.
--- Their game opens it (client/appearance.lua), and still refuses there if the editor is already open.
---@param who number|table  a server id, or { charId = n } for a character who is online
---@return boolean ok
---@return string|nil why
function OpenCharacterEditorFor(who)
    local charId, found = WhoIs(who)
    if not charId then return false, found end   -- WhoIs's own words
    local player = found and Players[found]
    if not player then return false, 'That character is not online' end
    if player._inCreator then return false, 'They are still making their character' end
    if player.isDead then return false, 'They are down' end
    TriggerClientEvent('whip_core:client:openCharacterEditor', found)
    return true
end

exports('OpenCharacterEditor', function(who)
    return OpenCharacterEditorFor(who)
end)

SecureEvent('whip_core:server:saveAppearance', {
    rateLimit = 2000,
    params = { {'appearance', 'any'} },
}, function(source, player, appearance)
    -- Byte cap first — no point walking a table whose encoding is absurd.
    local encoded = json.encode(appearance)
    if not encoded or #encoded > 10000 then return end

    local sanitized, err = sanitizeAppearance(appearance)
    if not sanitized then
        return false, 'Appearance rejected: ' .. (err or 'invalid')   -- shown and recorded
    end

    player:setMetadata('appearance', sanitized)
    player:save()
    ShowSuccess(source, 'Appearance saved.')
end)

-- ============================================
-- Outfits (the character editor's Outfits tab)
-- ============================================
--
-- An outfit is the clothes and accessories a character had on, kept by name in their metadata (`outfits`) so
-- the editor can put them on again with one press. Never the face, hair or tattoos: those stay the character's,
-- whatever they wear. A save, an update, a rename and a delete are kept at once, apart from the editor's
-- Save; putting one on is an edit like any other there, kept by Save and walked back by Cancel.
--
-- One outfit: { id, name, model, components = { ['1'] = { drawable, texture }, ... }, props = { ['0'] = ... } }.
-- `id` names it to an update or a delete (its place in the list moves). `model` is the body it was made
-- on: a drawable number is another item on the other body. Every answer is the whole list, as kept.

local OUTFIT_COMPONENTS = { '1', '3', '4', '5', '6', '7', '8', '9', '10', '11' }   -- every slot but the face (0) and hair (2)
local OUTFIT_NAME_MAX = 30

local function outfitLimit()
    return clampInt(Config.Creator and Config.Creator.maxOutfits, 1, 100, 20)
end

--- The character's outfits, as a new list: a change is made on it and only then put back. The outfits
--- themselves are never changed in place: a changed one is a new table.
local function outfitsOf(player)
    local list, out = player:getMetadata('outfits'), {}
    if type(list) == 'table' then
        for _, o in ipairs(list) do
            if type(o) == 'table' and type(o.id) == 'number' then out[#out + 1] = o end
        end
    end
    return out
end

local function outfitAt(list, id)
    for i, o in ipairs(list) do
        if o.id == id then return i end
    end
    return nil
end

--- What the page sent, as an outfit: every clothing slot and prop, held to the appearance's own bounds. A
--- slot missing is refused, not filled: an outfit with no hat must take a hat off when it goes on.
---@return table|nil outfit
---@return string|nil why
local function sanitizeOutfit(outfit)
    if type(outfit) ~= 'table' then return nil, 'not a table' end
    if not APPEARANCE_MODELS[outfit.model] then return nil, 'bad model' end
    if type(outfit.components) ~= 'table' or type(outfit.props) ~= 'table' then return nil, 'missing clothes' end
    local out = { model = outfit.model, components = {}, props = {} }
    for _, key in ipairs(OUTFIT_COMPONENTS) do
        local c = outfit.components[key]
        if type(c) ~= 'table' then return nil, 'missing component ' .. key end
        out.components[key] = { drawable = clampInt(c.drawable, 0, 4095, 0), texture = clampInt(c.texture, 0, 127, 0) }
    end
    for key in pairs(APPEARANCE_PROP_IDS) do
        local p = outfit.props[key]
        if type(p) ~= 'table' then return nil, 'missing prop ' .. key end
        out.props[key] = { drawable = clampInt(p.drawable, -1, 4095, -1), texture = clampInt(p.texture, 0, 127, 0) }
    end
    return out
end

--- The name typed, tidied: one space between words and none at the ends ('' when nothing was typed).
local function tidyOutfitName(typed)
    return ((typed:gsub('%s+', ' ')):match('^ ?(.-) ?$'))
end

--- Put the list back on the character and save it. Answers the list, or false and why.
local function keepOutfits(player, list)
    local ok, why = player:setMetadata('outfits', #list > 0 and list or nil)
    if not ok then return false, why end
    player:save()
    return list
end

SecureCallback('whip_core:appearance:saveOutfit', {
    rateLimit = 1000, burst = 3,
    params = { { 'name', 'string', OUTFIT_NAME_MAX, '' }, { 'outfit', 'any' } },
}, function(_, player, typed, outfit)
    local clean, why = sanitizeOutfit(outfit)
    if not clean then return false, 'That outfit could not be saved (' .. why .. ')' end
    local list, limit = outfitsOf(player), outfitLimit()
    if #list >= limit then
        return false, ('You have %d outfits, the most one character keeps. Delete one to save another.'):format(limit)
    end
    local id, taken = 1, {}
    for _, o in ipairs(list) do
        if o.id >= id then id = math.floor(o.id) + 1 end
        if type(o.name) == 'string' then taken[o.name] = true end
    end
    -- Nothing typed: "Outfit N", the first N no outfit is called.
    local name, n = tidyOutfitName(typed), #list + 1
    if name == '' then
        while taken['Outfit ' .. n] do n = n + 1 end
        name = 'Outfit ' .. n
    end
    clean.id, clean.name = id, name
    list[#list + 1] = clean
    return keepOutfits(player, list)
end)

-- The clothes of a saved outfit, made what the character has on now; its name stays.
SecureCallback('whip_core:appearance:updateOutfit', {
    rateLimit = 1000, burst = 3,
    params = { { 'id', 'id' }, { 'outfit', 'any' } },
}, function(_, player, id, outfit)
    local clean, why = sanitizeOutfit(outfit)
    if not clean then return false, 'That outfit could not be saved (' .. why .. ')' end
    local list = outfitsOf(player)
    local at = outfitAt(list, id)
    if not at then return false, 'That outfit is not saved any more' end
    clean.id, clean.name = list[at].id, list[at].name
    list[at] = clean
    return keepOutfits(player, list)
end)

SecureCallback('whip_core:appearance:renameOutfit', {
    rateLimit = 500, burst = 3,
    params = { { 'id', 'id' }, { 'name', 'string', OUTFIT_NAME_MAX, '' } },
}, function(_, player, id, typed)
    local list = outfitsOf(player)
    local at = outfitAt(list, id)
    if not at then return false, 'That outfit is not saved any more' end
    local name, o = tidyOutfitName(typed), list[at]
    if name == '' or name == o.name then return list end   -- nothing new typed: it keeps its name
    list[at] = { id = o.id, name = name, model = o.model, components = o.components, props = o.props }
    return keepOutfits(player, list)
end)

SecureCallback('whip_core:appearance:deleteOutfit', {
    rateLimit = 500, burst = 3,
    params = { { 'id', 'id' } },
}, function(_, player, id)
    local list = outfitsOf(player)
    local at = outfitAt(list, id)
    if not at then return list end   -- already gone: the list as it is
    table.remove(list, at)
    return keepOutfits(player, list)
end)

-- ============================================
-- Shops — Player Events
-- ============================================

--- Open a shop for a player: the session, the basket, and the screen. Answers true, or false and
--- why. The ways in, each behind its own reach and requirements: the shop's counter prompt (server/shop_counters.lua),
--- a Systems card (server/systems/cards_places.lua), and whip_test's seam (__TestOpenShop). There is
--- no client event to open one (it would skip those requirements). Distance is the caller's to
--- check: purchases are held to the shop's own range anyway (Shops.inRange).
---@param source number
---@param player table  the live player
---@param shopId number|nil
---@return boolean ok
---@return string|nil reason
function Shops.openFor(source, player, shopId)
    local def = Shops.getDef(shopId)
    if not def then
        TriggerClientEvent('whip_core:client:openShop', source, nil)
        return false, 'Shop not found'
    end
    ---@cast shopId number   -- a shop was found by it

    -- Already has a shop open
    if Shops.openShopOf(source) then
        return false, 'You already have a shop open'
    end

    -- The session and its basket, before anything is drawn from them.
    Shops.beginSession(source, shopId)

    local shopPayload = Shops.buildShopPayload(shopId, player.charId)
    if not shopPayload then
        Shops.endSession(source)
        TriggerClientEvent('whip_core:client:openShop', source, nil)
        return false, 'Failed to load shop'
    end

    -- The shelf and the basket (Shops.buildScreenState). Merged here rather than inside
    -- buildShopPayload because the screen state is per PLAYER — it needs their basket — while the
    -- payload is per shop.
    shopPayload.screen = Shops.buildScreenState(source)

    -- Include player inventory data (same as openContainer / openInventory)
    local invBase = Inventory.buildPayload(player)
    for k, v in pairs(invBase) do shopPayload[k] = v end

    TriggerClientEvent('whip_core:client:openShop', source, shopPayload)
    local opened = { shopId = shopId, source = source, charId = player.charId }
    WhipEmit('whip_core:shop:opened', opened)
    Shops.talkOpened(source, shopId)   -- "What do you got?" (server/shop_talk.lua)
    return true
end

--- Close Shop
SecureEvent('whip_core:server:closeShop', {
    whileDead = true,   -- dying closes the screen, and the basket has to go back
    requirePlayer = false,
}, function(source, player)
    -- endSession, not a bare nil: anything still sitting in the basket is unpaid stock that has
    -- to go back on the shelf before the session is forgotten.
    Shops.talkLeft(source)   -- bought nothing: "Nevermind, I'll shop elsewhere" (server/shop_talk.lua)
    local shopId = Shops.endSession(source)
    if shopId and player then
        local closed = { shopId = shopId, source = source, charId = player.charId }
        WhipEmit('whip_core:shop:closed', closed)
    end
end)

--- Purchase from Shop
--- The basket is a server-side store, so the client only says how it would like to pay, and the
--- total it was shown, which the till compares and never charges (Shops.purchase).
SecureEvent('whip_core:server:shopPurchase', {
    rateLimit = 1000,
    params = {
        {'paymentMethod', 'enum', {'cash', 'bank'}},
        {'accountId', 'id', 0},   -- 0 = no account chosen (cash payment)
        {'expectedTotal', 'int', -1, 2000000000, -1},   -- -1 = not given
    },
}, function(source, _, paymentMethod, accountId, expectedTotal)
    -- Refusals are `return false, 'why'`: shown and recorded. The shop screen still hears
    -- the result on its own event, since it redraws from it.
    if not Shops.openShopOf(source) then
        return false, 'No shop open'
    end

    -- `kind` colours the screen's Buy: 'money' red "Not enough cash!", 'carry' amber
    -- "You can't carry all of this!", anything else red with the reason; a sale green.
    local ok, err, kind = Shops.purchase(source, paymentMethod, accountId, expectedTotal)
    if not ok then
        TriggerClientEvent('whip_core:client:shopPurchaseResult', source, { success = false, error = err, kind = kind })
        return false, err or 'Purchase failed'
    end
    TriggerClientEvent('whip_core:client:shopPurchaseResult', source, { success = true })
    ShowSuccess(source, 'Purchase complete!')
end)

--- Price the item on a stocked shop's slot (employee, from the stock view). The price is the
--- item's: every slot holding it takes it (Shops.setSlotPrice).
SecureEvent('whip_core:server:shopSetPrice', {
    rateLimit = 200,
    params = {
        {'shopId', 'id'},
        -- A stock container can have up to 1000 slots (the 24/7 shelf declares that many).
        {'slot', 'id', 1, 1000},
        {'price', 'int', 0, 999999999},
        {'forSale', 'bool'},
        -- What the press changes, and only that: the stock view's copy of the prices can be stale, so
        -- Mark For Sale keeps the item's price as the SERVER has it (keepPrice) and Set Price keeps its
        -- for-sale (keepSale).
        {'keepPrice', 'bool', false},
        {'keepSale', 'bool', false},
        -- The item pressed on: Set Price waits on a typed dialog, and the slot could be holding
        -- another item by the time the price lands. '': the page did not say (no check).
        {'item', 'string', 60, ''},
    },
    -- Standing at the shop, like every other deliberate press.
    near = {
        at = function(_, _, shopId)
            local def = Shops.getDef(shopId)
            if def then return def.x, def.y, def.z end
        end,
        range = 15.0,
    },
}, function(source, player, shopId, slot, price, forSale, keepPrice, keepSale, item)
    local def = Shops.getDef(shopId)
    if not def or def.mode ~= 'stocked' or not def.containerId then
        return false, 'Invalid shop'   -- shown and recorded
    end

    -- No job means nobody manages it, not everybody. Admin tools have their own ACE-gated path; a
    -- job-less shop simply has no employee-facing management.
    if not def.jobId or not Jobs.hasPermission(player.charId, def.jobId, 'canManage') then
        return false, 'No permission'
    end

    -- Asked, not assumed: "Price updated" only when the write took.
    -- (Explicit ifs: `x and false or nil` is nil, and forSale may be false.)
    local newPrice, newForSale = price, forSale
    if keepPrice then newPrice = nil end
    if keepSale then newForSale = nil end
    local ok, err = Shops.setSlotPrice(def.containerId, slot, newPrice, newForSale, item ~= '' and item or nil)
    if not ok then return false, err or 'Could not set the price' end
    ShowSuccess(source, 'Price updated')
end)

--- Open a stocked shop's stock for one of its managers: the stock container, priced. Answers true, or
--- false and why. Distance is the caller's to check (the event below, the shop's prompt:
--- server/shop_counters.lua); the container stays workable only near the shop.
---@param source number
---@param player table
---@param shopId number
---@return boolean ok
---@return string|nil reason
function Shops.openStockFor(source, player, shopId)
    local def = Shops.getDef(shopId)
    if not def or def.mode ~= 'stocked' or not def.containerId then
        return false, 'Invalid shop'
    end

    -- No job means nobody manages it (see shopSetPrice above).
    if not def.jobId or not Jobs.hasPermission(player.charId, def.jobId, 'canManage') then
        return false, 'No permission'
    end

    -- Reuse the existing container open flow — the shop's stock IS a container
    local containerId = def.containerId
    local containerDef = Containers.getDef(containerId)
    if not containerDef then
        return false, 'Stock container not found'
    end

    -- Join the stock container's viewers, anchored to the shop: the open was distance-checked at the
    -- counter (by the caller), so the stock stays workable only while the employee stays there.
    -- (tryOpen never refuses — it is a viewer set, not a lock — so the branch below is dormant.)
    local shopAnchor = { x = def.x, y = def.y, z = def.z, range = 20.0 }
    if not Containers.tryOpen(containerId, source, shopAnchor) then
        return false, 'Someone else is using this container'
    end

    -- Load inventory on-demand
    if not Containers.invCache[containerId] then
        Containers.loadInventory(containerId)
    end

    -- Load prices for overlay
    Shops.loadPrices(containerId)

    local payload = Inventory.buildPayload(player)
    payload.containerId     = containerId
    payload.containerDef    = Containers.serializeDef(containerId)
    payload.containerInv    = Containers.serializeInventory(containerId)
    payload.containerWeight = Containers.getWeight(containerId)
    -- Stock management extras
    payload.stockMode       = true
    payload.stockShopId     = shopId
    payload.stockPrices     = Shops.serializePrices(containerId)
    TriggerClientEvent('whip_core:client:openContainer', source, payload)
    return true
end

--- Open stocked shop for stock management (employee view)
SecureEvent('whip_core:server:openShopStock', {
    rateLimit = 500,
    -- Burst 3; see the note on openInventory in server/events_inventory.lua.
    burst     = 3,
    params = {
        {'shopId', 'id'},
    },
    -- Same guard as shopSetPrice above: this opens the stock CONTAINER.
    near = {
        at = function(_, _, shopId)
            local def = Shops.getDef(shopId)
            if def then return def.x, def.y, def.z end
        end,
        range = 15.0,
    },
}, function(source, player, shopId)
    -- Refusals are `return false, 'why'`: shown and recorded.
    local ok, why = Shops.openStockFor(source, player, shopId)
    if not ok then return false, why end
end)

-- ============================================
-- UI Library Tester — permission-gated open
-- ============================================

SecureEvent('whip_core:server:uitGetAccess', {
    ace = 'whip.devtools',
}, function(source)
    TriggerClientEvent('whip_core:client:uitAccessGranted', source)
end)

-- ============================================
-- Open Player Inventory System (events only)
-- ============================================
-- The session state (Inventory.playerInvSession), OpenPlayerInventory and
-- ClosePlayerInventorySession live in server/inventory.lua with the exports; these two
-- handlers are the client-facing doors to them.

--- Admin requests to open another player's inventory (ACE-gated)
SecureEvent('whip_core:server:openPlayerInventory', {
    ace = 'whip.devtools',
    rateLimit = 1000,
    params = {
        {'targetCharId', 'id'},   -- an address: rejected, never clamped
    },
}, function(source, _, targetCharId)
    -- Its `false, 'why'` is this event's answer: shown to the admin and recorded. `admin`: the one
    -- session that may destroy the target's items.
    return OpenPlayerInventory(source, targetCharId, nil, true)
end)

--- Close player inventory session. No client notify: the caller IS the client, whose UI
--- already closed.
SecureEvent('whip_core:server:closePlayerInventory', {
    whileDead = true,   -- dying closes the screen, and the target's lock has to go
    rateLimit = 500,
    -- Burst 3; see the note on openInventory in server/events_inventory.lua. This one closes an
    -- admin SESSION the server is holding — a drop leaves that session open with nothing left on
    -- either side to close it.
    burst     = 3,
}, function(source, player)
    local ok, session = ClosePlayerInventorySession(source, player, false)
    if ok and session then
        print(('[whip_core] %s [%d] closed player inventory session (target charId: %d)'):format(
            player.fullName, source, session.targetCharId
        ))
    end
end)
