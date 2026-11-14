-- ============================================
-- ACTORS — what a networked car is doing, run by the game that owns it
-- ============================================
--
-- A car of a Director run can play TASKS (server/director/tasks.lua): wait, teleport, freeze, speed up,
-- everyone out, the siren, its health, blow up, its doors, windows, lights, indicators, horn, alarm, engine,
-- tyres, roof, fire and dirt, and its lock (the one this file does itself: HOOKS.started). The car is whip's (a temporary car: server/vehicles.lua
-- made it, under the run's tag), and its physics run on whichever player's game OWNS it, which changes
-- as players come and go. So the server keeps what it is doing here, and the owner runs it, the way an
-- NPC's brain is run (server/npcs.lua):
--
--   * the record: the car (its entity, checked against its netId and model each look), its list as it
--     plays (server/task_seq.lua) and a version, bumped at each change
--   * the owner is sent the version (whip_core:client:actorJob) and applies it, then says so
--     (whip_core:server:actorApplied, only the car's owner may); not said, it is sent again each second
--   * a new owner is sent it at once, with how long its step has run, and carries on
--   * a step that waits for something (everyone out) is done when the owner says so
--     (whip_core:server:actorJob), or gives up
--   * a car left FROZEN by its list stays frozen: its record stays (with no list) so every new owner
--     holds it too, until the car goes
--   * a car's TRAILER (Actors.setTow: the Director's Tows, a truck made with it) goes in each version: its owner
--     hitches it (client/actors.lua). The record stays while it has one, so a new owner hitches it too
--   * its STATE, what its Lights, Indicators, Siren and Engine steps last set (a step's leftByDrives: they last on
--     the car, not on a game), goes in each version too, and a game that takes the car sets it again before its job.
--     The record stays while it has some
--   * the car gone (deleted, released with its run, or a different entity under its id): the record
--     ends, and whoever started the list hears 'gone'
--   * a TAKE (a recorded drive, a step of its list) plays on ONE game, the one the Director picked for its
--     run (its step's `pin`: every take of a run on the same game, so cars that hit each other do so on
--     one game, and the crash happens there exactly as recorded). That game is asked to take the car and
--     keep it (whip_core:client:actorPin), again every two seconds while another game owns it, and let go
--     of it when the take is over. Its owner is checked on every look; the take plays on whoever owns the
--     car meanwhile, from the same moment (the server's clock), so a hand-over costs nothing but a jolt.
--
--   * EXPERIMENTAL RECORDED DRIVES SYNC (Config.ExperimentalDriveSync): every game in the car's world is told which
--     take it plays and from when (whip_core:client:takeShow: its SHOW, and false when that is over), and every game
--     but the take's own plays it on a copy of the car only it has (client/take_copies.lua). A game that comes in
--     late asks for the shows going (whip_core:server:takeShowsWant). Hits on a copy come back here
--     (whip_core:server:takeCopyHit) and go to the owner of what was hit.
--
-- /npcdebug shows a car's record the way it shows an NPC's (owner, step, applied).

Actors = {}

local TICK_MS   = 250
local IDLE_MS   = 1000
local RESEND_MS = 1000
local PIN_GAP_MS = 2000   -- the game a take is pinned to is asked again this often while another owns the car
local PIN_WARN   = 5      -- ...and said in the console after this many asks

local recs  = {}   -- [actorId] = record
local byEnt = {}   -- [entity] = actorId
local nextId = 0

local function unsigned(h) return (tonumber(h) or 0) % 0x100000000 end

local function netOwnerOf(ent)
    local o = NetworkGetEntityOwner(ent)
    return (o and o > 0) and o or nil
end

--- Is the record's car still this entity? Server handles are reused.
local function isOurs(rec)
    local e = rec.ent
    return e ~= nil and DoesEntityExist(e) and GetEntityType(e) == 2 and NetworkGetNetworkIdFromEntity(e) == rec.netId
        and unsigned(GetEntityModel(e)) == unsigned(rec.hash)
end

local function push(rec, why)
    local owner = rec.ent and netOwnerOf(rec.ent)
    rec.lastPush = why
    if not owner then return end
    local now = GetGameTimer()
    rec.sentTo, rec.sentAt = owner, now
    TriggerClientEvent('whip_core:client:actorJob', owner, rec.id, rec.netId, rec.ver,
        { job = TaskSeq.wire(rec, now), frozen = rec.frozen, tow = rec.tow, state = rec.state })
end

local function bump(rec, why)
    rec.ver = rec.ver + 1
    rec.acked = 0
    push(rec, why)
end

local HOOKS   -- (declared first: its own end hook ends a trailer's list with it)
HOOKS = {
    bump = function(rec, why) bump(rec, why) end,
    name = function(rec) return ('car %s (actor %d)'):format(tostring(rec.netId), rec.id) end,
    -- Over: a car its list left frozen stays frozen (the record holds it for every later owner), as an NPC's does
    -- (server/npcs.lua): only a list that ended 'done' and does not go round; one put in place of another
    -- (`rec.replacing`) is not the end of anything, and the new list's own push follows.
    ended = function(rec, why, seq)
        rec.frozen = (why == 'done' and seq.after ~= 'loop' and seq.frozen == true) or nil
        if not rec.gone and not rec.replacing then bump(rec, 'tasks over') end
        -- Stopped (Stop Tasks, another list in its place, the car gone), what played beside it goes too: its trailers'
        -- takes (Actors.runTasks opts.with), each still on the list it was given then. Done, they end on their own.
        if why ~= 'done' then
            for fid, fseq in pairs(seq.followers or {}) do
                local f = recs[fid]
                if f and f.seq == fseq then TaskSeq.finish(f, 'stopped', HOOKS) end
            end
        end
    end,
    -- A job under way on its owner's game: its Lock or Unlock is whip's own lock, the server's (every game, and the
    -- car's record, as a player's key does it). Its Everyone Out lets whip's NPCs riding it off their ride (each
    -- one's watch would seat it again).
    started = function(rec, list)
        for _, s in ipairs(list or {}) do
            if s.t == 'lock' and isOurs(rec) then
                local vid = Vehicles.getEntityVehicleId(rec.ent)
                if vid then Vehicles.setLocked(vid, not (s.p and s.p.on == false)) end
            elseif s.t == 'everyoneOut' and rec.netId then
                Npcs.leaveRide(rec.netId)
            end
            -- What it leaves set on the car (its lights, its siren): the car's state, not its game's.
            if DirectorSteps.is(s.t, 'leftByDrives') then
                rec.state = rec.state or {}
                rec.state[s.t] = { t = s.t, p = s.p }
            end
        end
    end,
}

local function forget(rec)
    recs[rec.id] = nil
    if rec.ent and byEnt[rec.ent] == rec.id then byEnt[rec.ent] = nil end
end

--- Let the game a take was pinned to keep the car no longer.
local function unpin(rec)
    if rec.pinned and GetPlayerName(rec.pinned) then
        TriggerClientEvent('whip_core:client:actorPin', rec.pinned, rec.id, rec.netId, false)
    end
    rec.pinned, rec.pinAt, rec.pinTries = nil, nil, nil
end

--- The game the current job's take is pinned to, or nil (no take in it, or that player has gone).
local function pinOf(rec)
    for _, s in ipairs(rec.job and rec.job.list or {}) do
        if DirectorSteps.is(s.t, 'playsTake') and s.p and s.p.pin and GetPlayerName(s.p.pin) then return s.p.pin end
    end
    return nil
end

--- Keep a take's car on its game: asked to take it while another game owns it; let go when the take is over.
local function keepPinned(rec, owner, now)
    local want = pinOf(rec)
    if want ~= rec.pinned then
        unpin(rec)
        rec.pinned, rec.pinAt, rec.pinTries = want, 0, 0
    end
    if not rec.pinned or owner == rec.pinned or now - rec.pinAt < PIN_GAP_MS then return end
    rec.pinAt = now
    rec.pinTries = rec.pinTries + 1
    TriggerClientEvent('whip_core:client:actorPin', rec.pinned, rec.id, rec.netId, true)
    if rec.pinTries == PIN_WARN then
        print(('^3[whip_core:actors] car %s: player %d has been asked %d times to take it for its take, and %s still owns it^7')
            :format(tostring(rec.netId), rec.pinned, PIN_WARN, owner and ('player ' .. owner) or 'nobody'))
    end
end

-- ---- shows: the take each car plays, told to every game in its world ----

local shows = {}   -- [netId] = { show = { take, startAt, pin, tow }, bucket, key }

--- The take this car plays now, as every game is told it, or nil: its job's step under way is a take, and the
--- setting is on.
local function showOf(rec)
    if not Config.ExperimentalDriveSync then return nil end
    local list = rec.job and rec.job.list
    local s = list and list[#list]
    if not (s and DirectorSteps.is(s.t, 'playsTake') and type(s.p) == 'table' and s.p.take and s.p.startAt) then return nil end
    return { take = s.p.take, startAt = s.p.startAt, pin = s.p.pin, tow = s.p.tow, leave = s.p.leave }
end

--- Every player in a routing bucket.
local function playersIn(bucket)
    local out = {}
    for _, p in ipairs(GetPlayers()) do
        local src = tonumber(p)
        if src and GetPlayerRoutingBucket(src) == bucket then out[#out + 1] = src end
    end
    return out
end

--- Tell every game in the car's world when its show starts, changes or ends (false).
local function tellShow(rec)
    local show = (not rec.gone and rec.ent and isOurs(rec)) and showOf(rec) or nil
    local key = show and (tostring(show.take) .. ':' .. tostring(show.startAt) .. ':' .. tostring(show.pin)) or nil
    local had = shows[rec.netId]
    if (had and had.key) == key then return end
    if show then
        local bucket = GetEntityRoutingBucket(rec.ent)
        shows[rec.netId] = { show = show, bucket = bucket, key = key, ent = rec.ent }
        for _, src in ipairs(playersIn(bucket)) do TriggerClientEvent('whip_core:client:takeShow', src, rec.netId, show) end
    else
        shows[rec.netId] = nil
        for _, src in ipairs(playersIn(had.bucket)) do TriggerClientEvent('whip_core:client:takeShow', src, rec.netId, false) end
    end
end

--- The record ends: its list too (whoever started it hears why). Never waits.
local function retire(rec, why)
    if rec.gone then return end
    rec.gone = true
    unpin(rec)
    forget(rec)
    TaskSeq.finish(rec, why or 'gone', HOOKS)
    tellShow(rec)
end

-- A record belongs to the resource that made it, under its run's tag: released with the run.
local reg = Registry.new('actor', {
    label = 'car tasks',
    scoped = true,
    releaseOrder = 25,   -- before the run's temp cars (30): the list hears 'gone' while the car is still there
    same = false,
    onRemove = function(_, rec, _, why) retire(rec, why) end,
})

local function tickOne(rec, now)
    if not isOurs(rec) then
        reg:remove(rec.owner, rec.id)   -- onRemove retires it
        return
    end
    local owner = netOwnerOf(rec.ent)
    if owner ~= rec.netOwner then
        rec.netOwner = owner
        rec.acked = 0
        if owner then push(rec, 'new owner') end
    elseif owner and rec.acked ~= rec.ver and now - (rec.sentAt or 0) >= RESEND_MS then
        push(rec, 'not applied yet')
    end
    if rec.seq then TaskSeq.tick(rec, now, HOOKS) end
    keepPinned(rec, owner, now)
    tellShow(rec)
    -- Nothing left to hold: done with it. (A trailer to hitch, or its state, is held: each new owner is sent it.)
    if not rec.seq and not rec.frozen and not rec.tow and not rec.state and rec.acked == rec.ver then reg:remove(rec.owner, rec.id) end
end

Every('actors', IDLE_MS, function()
    if next(recs) == nil then return IDLE_MS end
    local now = GetGameTimer()
    local ids = {}
    for id in pairs(recs) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local rec = recs[id]
        if rec and not rec.gone then
            local ok, err = pcall(tickOne, rec, now)
            if not ok then print(('[whip_core:actors] actor %d tick failed: %s'):format(id, tostring(err))) end
        end
    end
    return next(recs) and TICK_MS or IDLE_MS
end)

--- Start a car's tasks (or replace the ones it plays: those end 'stopped').
---@param owner string   Registry.caller()
---@param entity number  a car whip made (server entity)
---@param plan table     DirectorTasks.compile's plan
---@param opts table     { tag, resolve, onEnd, log, from, with = a car whose list this plays beside (a trailer's take
---                       beside its truck's): stopped with that list }
---@return number|false actorId
---@return string|nil why
function Actors.runTasks(owner, entity, plan, opts)
    opts = type(opts) == 'table' and opts or {}
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then return false, 'not a car' end
    if type(plan) ~= 'table' or type(plan.steps) ~= 'table' or #plan.steps == 0 then return false, 'no steps' end
    if type(opts.resolve) ~= 'function' then return false, 'resolve is a function' end
    local id = byEnt[entity]
    local rec = id and recs[id]
    if rec and (rec.owner ~= owner or not isOurs(rec)) then rec = nil end
    if not rec then
        nextId = nextId + 1
        rec = { id = nextId, owner = owner, ent = entity, netId = NetworkGetNetworkIdFromEntity(entity),
                hash = GetEntityModel(entity), ver = 1, acked = 0 }
        local ok, why = reg:add(owner, rec.id, rec, opts.tag and { tag = opts.tag } or nil)
        if not ok then return false, why --[[@as string]] end
        recs[rec.id] = rec
        byEnt[entity] = rec.id
    end
    -- (As an NPC's: the list it had ends without a push of its own, the new one's first job is the one push.)
    rec.replacing = rec.seq ~= nil or nil
    local before = rec.ver
    local ok, err = pcall(TaskSeq.start, rec, plan, opts, HOOKS)
    rec.replacing = nil
    if rec.ver == before and not rec.gone then bump(rec, 'tasks') end
    if not ok then return false, tostring(err) end
    local leadId = opts.with and byEnt[opts.with]
    local lead = leadId and recs[leadId]
    if lead and lead ~= rec and lead.seq and rec.seq then
        lead.seq.followers = lead.seq.followers or {}
        lead.seq.followers[rec.id] = rec.seq
    end
    return rec.id
end

--- A car's trailer (the Director's Tows: a truck made with it): its owner hitches it as it gets the car, and so does
--- each new owner for a while (client/actors.lua TOW_TRY_MS; one let go since stays let go). nil: none any more.
---@param owner string   Registry.caller()
---@param entity number  a car whip made (server entity)
---@param trailer number|nil  its trailer (server entity), or nil
---@param opts table|nil  { tag }
---@return number|false actorId
---@return string|nil why
function Actors.setTow(owner, entity, trailer, opts)
    opts = type(opts) == 'table' and opts or {}
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then return false, 'not a car' end
    local net = nil
    if trailer then
        if trailer == 0 or not DoesEntityExist(trailer) or GetEntityType(trailer) ~= 2 then return false, 'its trailer is not a vehicle' end
        net = NetworkGetNetworkIdFromEntity(trailer)
    end
    local id = byEnt[entity]
    local rec = id and recs[id]
    if rec and (rec.owner ~= owner or not isOurs(rec)) then rec = nil end
    if not rec then
        if not net then return false, 'it has no trailer' end
        nextId = nextId + 1
        rec = { id = nextId, owner = owner, ent = entity, netId = NetworkGetNetworkIdFromEntity(entity),
                hash = GetEntityModel(entity), ver = 1, acked = 0 }
        local ok, why = reg:add(owner, rec.id, rec, opts.tag and { tag = opts.tag } or nil)
        if not ok then return false, why --[[@as string]] end
        recs[rec.id] = rec
        byEnt[entity] = rec.id
    end
    if rec.tow ~= net then
        rec.tow = net
        bump(rec, 'its trailer')
    end
    return rec.id
end

--- Stop a car's tasks. Answers the step it would pick up again from (TaskSeq.resumeAt), or false.
function Actors.stopTasks(owner, actorId)
    local rec = recs[actorId]
    if not rec or rec.owner ~= owner or not rec.seq then return false end
    local at = TaskSeq.resumeAt(rec)
    TaskSeq.finish(rec, 'stopped', HOOKS)
    return at
end

--- A car's tasks as they stand ({ i, n, laps, applied }), or nil.
function Actors.tasksOf(actorId)
    local rec = recs[actorId]
    return rec and TaskSeq.state(rec) or nil
end

--- The game a recorded drive moves this car on, or nil. While its job has a take, that is the take's pin (asked to keep
--- the car for the whole job: keepPinned), read from the job itself, never from the last tick. With no game pinned and a
--- take under way, it is whoever owns the car (a take plays on its owner). nil: no take in its job.
function Actors.takeDriver(entity)
    local rec = entity and recs[byEnt[entity]]
    if not rec or rec.gone or not isOurs(rec) then return nil end
    local pin = pinOf(rec)
    if pin then return pin end
    local list = rec.job and rec.job.list
    local s = list and list[#list]
    if s and DirectorSteps.is(s.t, 'playsTake') then return netOwnerOf(rec.ent) end
    return nil
end

--- GetVehicleDriver(vehicle) -> source, how | nil. Whose game drives a car now: the player in its driver's seat
--- ('seat'), or the player's game a recorded drive (a Director take) plays it on ('take'). nil for a car nobody drives
--- (parked, an NPC at the wheel), or no car. A resource that pulls or carries a car (a rope, a tow) asks this before
--- taking the car to another game: a take's game takes it back every two seconds, and the two would fight.
---     local source, how = exports.whip_core:GetVehicleDriver({ netId = netId })
--- `vehicle`: a vehicleId, or { netId } | { entity } (any networked car, whip's or not) | { plate }.
exports('GetVehicleDriver', function(vehicle)
    local entity
    if type(vehicle) == 'table' and (vehicle.entity ~= nil or vehicle.netId ~= nil) then
        entity = tonumber(vehicle.entity)
        if not entity then
            local netId = Sanitize.id(vehicle.netId)
            entity = netId and NetworkGetEntityFromNetworkId(netId) or nil
        end
    else
        local vehicleId = Vehicles.idFromRef(vehicle)
        entity = vehicleId and Vehicles.getEntity(vehicleId) or nil
    end
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then return nil end
    local ped = GetPedInVehicleSeat(entity, -1)
    if ped and ped ~= 0 and IsPedAPlayer(ped) then
        local src = NetworkGetEntityOwner(ped)   -- a player's ped is their own game's
        if src and src > 0 then return src, 'seat' end
    end
    local src = Actors.takeDriver(entity)
    if src then return src, 'take' end
    return nil
end)

--- The id of the record for a car (its entity), or nil.
function Actors.of(entity)
    return entity and byEnt[entity] or nil
end

--- What /npcdebug shows of the records near a point: { id, net, owner, ver, acked, job }.
function Actors.near(at, range)
    local out = {}
    local now = GetGameTimer()
    for _, rec in pairs(recs) do
        if rec.ent and DoesEntityExist(rec.ent) then
            local c = GetEntityCoords(rec.ent)
            local dx, dy, dz = c.x - at.x, c.y - at.y, c.z - at.z
            if dx * dx + dy * dy + dz * dz <= range * range then
                out[#out + 1] = { id = rec.id, net = rec.netId, owner = netOwnerOf(rec.ent) or 0, ver = rec.ver,
                                  acked = rec.acked, frozen = rec.frozen == true, job = TaskSeq.view(rec, now),
                                  pinned = rec.pinned or 0 }
            end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- ============================================
-- From the owning game
-- ============================================

SecureEvent('whip_core:server:actorApplied', {
    rateLimit = 50, burst = 40, whileDead = true,
    params = { {'actorId', 'id'}, {'netId', 'id', 1, 65535}, {'ver', 'int', 0, 1000000} },
    ownerOf = 'netId',
}, function(_, _, actorId, netId, ver)
    local rec = recs[actorId]
    if not rec or rec.netId ~= netId then return end
    if ver == rec.ver then rec.acked = ver end
end)

SecureEvent('whip_core:server:actorJob', {
    rateLimit = 50, burst = 40, whileDead = true,
    params = { {'actorId', 'id'}, {'netId', 'id', 1, 65535}, {'jobId', 'int', 0, 2000000000}, {'how', 'enum', { 'done', 'failed' }} },
    ownerOf = 'netId',
}, function(_, _, actorId, netId, jobId, how)
    local rec = recs[actorId]
    if not rec or rec.netId ~= netId then return end
    TaskSeq.report(rec, jobId, how)
end)

-- ---- shows, for the games that play copies (client/take_copies.lua) ----

--- A game come in late (loaded, or whip restarted): every show going in its world.
SecureEvent('whip_core:server:takeShowsWant', {
    rateLimit = 2000, burst = 2, whileDead = true,
}, function(source)
    local bucket = GetPlayerRoutingBucket(source)
    for netId, s in pairs(shows) do
        if s.bucket == bucket then TriggerClientEvent('whip_core:client:takeShow', source, netId, s.show) end
    end
end)

-- A HIT ON A COPY is a player's word, so it is taken only as far as it could be true: from someone who could have
-- done it (a gun out, or driving: a ram; never from inside the car itself), within the range copies are drawn at, and
-- at most what a player could do in a second (HIT_CAR_S off a car's body and engine together, HIT_PED_S off one rider,
-- whatever the reports say). Only whip's NPC riders take a hit this way: a player's ped never does (their game and
-- whip's own rules decide what hurts a player).
local HIT_NEAR  = 350.0    -- as far as a copy is drawn (client/take_copies.lua COPY_RANGE)
local HIT_CAR_S = 300.0
local HIT_PED_S = 100.0
local UNARMED   = GetHashKey('WEAPON_UNARMED')
local hitBudget = {}       -- [source] = { sec, car = { [netId] = used }, ped = { [pedNet] = used } }

local function budgetOf(source)
    local sec = GetGameTimer() // 1000
    local b = hitBudget[source]
    if not b or b.sec ~= sec then
        b = { sec = sec, car = {}, ped = {} }
        hitBudget[source] = b
    end
    return b
end

--- Up to `want` of what is left of `per` this second for `key` in `map`.
local function spend(map, key, want, per)
    local used = map[key] or 0
    local d = math.max(0.0, math.min(want, per - used))
    map[key] = used + d
    return d
end

--- Damage a player did to their copy of a show's car, or to a rider's copy: passed to the game that owns what was hit
--- (client/take_copies.lua applies it there).
SecureEvent('whip_core:server:takeCopyHit', {
    rateLimit = 100, burst = 10,
    params = { { 'netId', 'id', 1, 65535 }, { 'hit', 'any' } },
}, function(source, _, netId, hit)
    local s = shows[netId]
    if not s or type(hit) ~= 'table' or not (s.ent and DoesEntityExist(s.ent)) then return end
    if GetPlayerRoutingBucket(source) ~= s.bucket then return end
    local me = GetPlayerPed(source)
    if not me or me == 0 or #(GetEntityCoords(me) - GetEntityCoords(s.ent)) > HIT_NEAR then return end
    local inCar = GetVehiclePedIsIn(me, false)
    if inCar == s.ent then return end
    if GetSelectedPedWeapon(me) == UNARMED and (not inCar or inCar == 0) then return end
    local function amount(v) v = tonumber(v) return v and v == v and math.max(0.0, math.min(1000.0, v)) or 0.0 end
    local b = budgetOf(source)
    local body, engine = amount(hit.body), amount(hit.engine)
    local allowed = spend(b.car, netId, body + engine, HIT_CAR_S)
    local scale = (body + engine) > 0 and allowed / (body + engine) or 0
    local car = { body = body * scale, engine = engine * scale, tyres = {}, by = source }
    for _, i in ipairs(type(hit.tyres) == 'table' and hit.tyres or {}) do
        i = math.tointeger(tonumber(i))
        if i and i >= 0 and i <= 7 and #car.tyres < 8 then car.tyres[#car.tyres + 1] = i end
    end
    local owner = NetworkGetEntityOwner(s.ent)
    if owner and owner > 0 and (car.body > 0 or car.engine > 0 or #car.tyres > 0) then
        TriggerClientEvent('whip_core:client:takeCopyHit', owner, netId, car)
    end
    -- A rider's copy: its ped, if it is a whip NPC in or on this car, to the game that owns that ped.
    local n = 0
    for pedNet, v in pairs(type(hit.peds) == 'table' and hit.peds or {}) do
        n = n + 1
        if n > 16 then break end
        pedNet = math.tointeger(tonumber(pedNet))
        local ped = pedNet and NetworkGetEntityFromNetworkId(pedNet)
        if ped and ped ~= 0 and DoesEntityExist(ped) and GetEntityType(ped) == 1 and not IsPedAPlayer(ped)
            and (GetVehiclePedIsIn(ped, false) == s.ent or GetEntityAttachedTo(ped) == s.ent) then
            local d = spend(b.ped, pedNet, amount(v), HIT_PED_S)
            local po = NetworkGetEntityOwner(ped)
            if d > 0 and po and po > 0 then TriggerClientEvent('whip_core:client:takeCopyHit', po, pedNet, { ped = d, by = source }) end
        end
    end
end)

AddEventHandler('playerDropped', function() hitBudget[source] = nil end)

-- whip_core stopping: nothing to delete (the cars are server/vehicles.lua's), only the lists to end.
CoreStop.add(14, 'actors: end', function()
    for _, rec in pairs(recs) do rec.gone = true end
    recs, byEnt = {}, {}
end)
