-- Actors, the owner's half (server/actors.lua): runs a car's tasks on the game that owns it.
-- The server sends a car's version (its job step, and whether it is frozen); this game applies it and says so.
--   * a job runs once; a resent version is only said again. A job taken over part-way runs only the step that
--     takes time (a once step never repeats).
--   * Speed Up To holds the speed for its time; Everyone Out is said done once every seat is empty.
--   * Play a Take drives the car along a recording (shared/take_track.lua) by the server's clock (client/clock.lua):
--     speed and spin are set each frame with a pull back toward place (hard reset only past 3 m or 30 degrees),
--     so GTA moves it. Samples are asked for once (whip_core:server:takeWant) and kept; the version is said
--     applied only once they are here.
--   * When someone sits in a car a take plays, the take has the engine (TakePlayer.on) and the dial gear
--     (TakePlayer.gearOn).
-- One watch loop looks at every car this game runs (quarter second, a tenth while holding a speed); a per-frame
-- thread runs only while a take plays.

local SAY_MS = 2000
local CATCH_UP = 10.0   -- a take: speed added per metre off the path (m/s per m), and spin per radian off
local WARP_OFF = 3.0    -- ...further off than this (m) and it is put back on the path
local TURN_OFF = 0.5    -- ...turned further off than this (radians) and it is put back too

local watches = {}   -- [netId] = { id, ver, data, ran, look, saidAt, speed, play }
local takes = {}     -- [take id] = its samples (a flat list), once here
local asked = {}     -- [take id] = when it was asked for
local takeUsed = {}  -- [take id] = when it was last used: the TAKES_KEPT used last are kept (a long take is MBs)
local TAKES_KEPT = 8

--- A take's samples kept here; the oldest-used go past TAKES_KEPT (asked for again if wanted: missingTakes).
--- A take playing now holds its own list.
local function keepTake(id, samples)
    takes[id], takeUsed[id] = samples, GetGameTimer()
    local n = 0
    for _ in pairs(takes) do n = n + 1 end
    while n > TAKES_KEPT do
        local oldest, at = nil, math.huge
        for k in pairs(takes) do
            if (takeUsed[k] or 0) < at then oldest, at = k, takeUsed[k] or 0 end
        end
        -- (More than TAKES_KEPT kept: one was found.)
        ---@cast oldest -nil
        takes[oldest], takeUsed[oldest], asked[oldest] = nil, nil, nil
        n = n - 1
    end
end

--- A take's samples, marked used now, or nil.
local function takeOf(id)
    local t = id and takes[id]
    if t then takeUsed[id] = GetGameTimer() end
    return t
end

-- (A car from its network id, and whether this game runs it: DirectorKit, shared/director/kit.lua.)
local function vehFor(netId) return DirectorKit.entityOfNet(netId, 2) end
local mine = DirectorKit.mine

local STEP = {}

STEP.wait = function() end

STEP.teleport = function(veh, _, s)
    local a = s.p.at
    SetEntityCoordsNoOffset(veh, a.x, a.y, a.z, false, false, false)
    SetEntityHeading(veh, a.heading or 0.0)
    SetEntityVelocity(veh, 0.0, 0.0, 0.0)
end

STEP.freeze = function() end   -- (the version's `frozen`: the watch holds it)

STEP.speedTo = function(_, w, s, left)
    w.speed = { mps = s.p.mps or 15.0, untilAt = GetGameTimer() + left }
end

-- Everyone in it is told to get out as an NPC's own Get Out does (client/npcs.lua), this game's player too; another
-- player's ped is theirs to move. (TaskEveryoneLeaveVehicle leaves a whip NPC seated.)
STEP.everyoneOut = function(veh)
    local me = PlayerPedId()
    for seat = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
        local ped = GetPedInVehicleSeat(veh, seat)
        if ped and ped ~= 0 then
            local p = IsPedAPlayer(ped)
            if ped == me or not (p == true or p == 1) then TaskLeaveVehicle(ped, veh, 0) end
        end
    end
    return { empty = true }
end

STEP.siren = function(veh, _, s)
    SetVehicleSiren(veh, s.p.on ~= false)
end

STEP.setHealth = function(veh, _, s)
    local pct = (s.p.pct or 100) / 100
    SetVehicleEngineHealth(veh, 1000.0 * pct)
    SetVehicleBodyHealth(veh, 1000.0 * pct)
    SetVehiclePetrolTankHealth(veh, 1000.0 * math.max(pct, 0.3))
end

STEP.blowUp = function(veh)
    NetworkExplodeVehicle(veh, true, false, false)
end

STEP.brake = function(veh, w, _, left)
    SetVehicleHandbrake(veh, true)
    SetVehicleBrakeLights(veh, true)
    w.brakeUntil = GetGameTimer() + left
end

-- Doors, windows, lights, horn, engine and tyres (server/director/tasks.lua).
-- GTA's numbers by place: doors 0-5 (bonnet 4, boot 5), windows 0-3, wheels 0, 1, 4, 5 (a bike's front 0, back 4).
local DOOR_N   = { ['front left'] = 0, ['front right'] = 1, ['back left'] = 2, ['back right'] = 3, ['bonnet'] = 4, ['boot'] = 5 }
local WINDOW_N = { ['front left'] = 0, ['front right'] = 1, ['back left'] = 2, ['back right'] = 3 }
local TYRE_N   = { ['front left'] = 0, ['front right'] = 1, ['back left'] = 4, ['back right'] = 5 }

--- The one a step names, or every one ('all of them').
local function each(map, which, all)
    if map[which] then return { map[which] } end
    return all
end

STEP.door = function(veh, _, s)
    for _, d in ipairs(each(DOOR_N, s.p.door, { 0, 1, 2, 3, 4, 5 })) do
        if s.p.how == 'shut' then SetVehicleDoorShut(veh, d, false) else SetVehicleDoorOpen(veh, d, false, false) end
    end
end

STEP.windows = function(veh, _, s)
    for _, i in ipairs(each(WINDOW_N, s.p.window, { 0, 1, 2, 3 })) do
        if s.p.how == 'up' then RollUpWindow(veh, i)
        elseif s.p.how == 'smashed' then SmashVehicleWindow(veh, i)
        else RollDownWindow(veh, i) end
    end
end

STEP.lights = function(veh, w, s)
    w.flash = nil
    SetVehicleLights(veh, s.p.lights == 'off' and 1 or s.p.lights == 'on' and 2 or 0)
    SetVehicleFullbeam(veh, s.p.beam == true)
    SetVehicleInteriorlight(veh, s.p.inside == true)
end

-- Flashes on and off for its time (the watch), then as GTA has them.
STEP.flashLights = function(_, w, _, left)
    w.flash = { untilAt = GetGameTimer() + left, on = false }
end

STEP.indicators = function(veh, _, s)
    local side = s.p.side
    -- (GTA's 1 is the left, 0 the right.)
    SetVehicleIndicatorLights(veh, 1, side == 'left' or side == 'hazards')
    SetVehicleIndicatorLights(veh, 0, side == 'right' or side == 'hazards')
end

-- THE HORN FOR ITS TIME, SOUNDED AGAIN AT EACH LOOK (lookAt), a little at a time: given its whole time at once, GTA
-- sounded it on after its list was stopped (WLVF's review). Its job ending stops it (endTimed).
local HORN = GetHashKey('HELDDOWN')
local HORN_MS = 400   -- each time it is sounded: longer than a look's gap, so it never drops between them

STEP.horn = function(veh, w, _, left)
    w.horn = { untilAt = GetGameTimer() + left }
    StartVehicleHorn(veh, math.floor(math.min(HORN_MS, left)), HORN, false)
end

STEP.alarm = function(veh)
    SetVehicleAlarm(veh, true)
    StartVehicleAlarm(veh)
end

STEP.engine = function(veh, _, s)
    if s.p.how == 'on' then
        SetVehicleEngineOn(veh, true, true, false)
    else
        -- Smoking: engine health low enough to smoke (under 300), and off.
        if s.p.how == 'smoking, stalled' then SetVehicleEngineHealth(veh, 150.0) end
        SetVehicleEngineOn(veh, false, true, true)
    end
end

STEP.tyres = function(veh, _, s)
    for _, t in ipairs(each(TYRE_N, s.p.tyre, { 0, 1, 2, 3, 4, 5 })) do
        if s.p.how == 'fixed' then
            SetVehicleTyreFixed(veh, t)
        else
            SetVehicleTyresCanBurst(veh, true)
            SetVehicleTyreBurst(veh, t, true, 1000.0)
        end
    end
end

STEP.roof = function(veh, _, s)
    if not IsVehicleAConvertible(veh, false) then return end
    if s.p.how == 'up' then RaiseConvertibleRoof(veh, false) else LowerConvertibleRoof(veh, false) end
end

-- Engine alight (health under 0 burns): it burns, and in time blows up.
STEP.fire = function(veh)
    SetVehicleEngineHealth(veh, -100.0)
end

STEP.dirt = function(veh, _, s)
    SetVehicleDirtLevel(veh, 15.0 * math.max(0, math.min(100, tonumber(s.p.pct) or 100)) / 100)
end

STEP.lock = function() end   -- (whip's own locks: the server's, as the step starts: server/actors.lua)

-- Takes

local FLAG = TakeTrack.FLAG
local K = TakeTrack.STRIDE

-- What a drive leaves to the car's own tasks (its step's `leave`; steps flagged leftByDrives in
-- shared/director/steps.lua), as the take's flag bits: never set from the recording.
local LEAVE_BITS = { lights = FLAG.lights | FLAG.fullbeam, indicators = FLAG.left | FLAG.right, siren = FLAG.siren,
                     engine = FLAG.engine }

local function leaveMask(leave)
    local m = 0
    if type(leave) ~= 'table' then return m end
    for k, bits in pairs(LEAVE_BITS) do if leave[k] then m = m | bits end end
    return m
end

--- Lights and so on: brake lights, handbrake and horn every frame, the rest on change (or `force`), except what
--- the drive leaves to the car's tasks (play.skip).
local function flags(veh, play, fl, force)
    fl = math.tointeger(fl) or 0
    SetVehicleBrakeLights(veh, fl & FLAG.brake ~= 0)
    SetVehicleHandbrake(veh, fl & FLAG.handbrake ~= 0)
    if fl & FLAG.horn ~= 0 then SoundVehicleHornThisFrame(veh) end
    local was = play.flags
    if fl == was and not force then return end
    play.flags = fl
    local skip = play.skip or 0
    local function flipped(bit) return skip & bit == 0 and (force or (was & bit) ~= (fl & bit)) end
    if flipped(FLAG.engine) then SetVehicleEngineOn(veh, fl & FLAG.engine ~= 0, true, true) end
    if flipped(FLAG.lights) then SetVehicleLights(veh, fl & FLAG.lights ~= 0 and 3 or 4) end
    if flipped(FLAG.fullbeam) then SetVehicleFullbeam(veh, fl & FLAG.fullbeam ~= 0) end
    if flipped(FLAG.left) then SetVehicleIndicatorLights(veh, 1, fl & FLAG.left ~= 0) end
    if flipped(FLAG.right) then SetVehicleIndicatorLights(veh, 0, fl & FLAG.right ~= 0) end
    if flipped(FLAG.siren) then SetVehicleSiren(veh, fl & FLAG.siren ~= 0) end
end

--- The car where the take has it at time t. `hold`: placed and held still (before its start).
local function pose(veh, play, t, hold)
    local out = play.out
    play.cur = TakeTrack.at(play.keys, play.n, t, play.cur, out, K)
    local vx, vy, vz = out[9], out[10], out[11]
    local sx, sy, sz = out.sx, out.sy, out.sz
    local follow = not hold and not play.warpNext
    if follow then
        local c = GetEntityCoords(veh)
        local dx, dy, dz = out[2] - c.x, out[3] - c.y, out[4] - c.z
        local qx, qy, qz, qw = GetEntityQuaternion(veh)
        local rx, ry, rz = TakeTrack.turn(qx, qy, qz, qw, out[5], out[6], out[7], out[8])
        if dx * dx + dy * dy + dz * dz > WARP_OFF * WARP_OFF or math.sqrt(rx * rx + ry * ry + rz * rz) > TURN_OFF then
            follow = false
        else
            vx, vy, vz = vx + dx * CATCH_UP, vy + dy * CATCH_UP, vz + dz * CATCH_UP
            sx, sy, sz = sx + rx * CATCH_UP, sy + ry * CATCH_UP, sz + rz * CATCH_UP
        end
    end
    if not follow then
        SetEntityCoordsNoOffset(veh, out[2] + 0.0, out[3] + 0.0, out[4] + 0.0, false, false, false)
        SetEntityQuaternion(veh, out[5] + 0.0, out[6] + 0.0, out[7] + 0.0, out[8] + 0.0)
        play.warpNext = false
    end
    if hold then
        SetEntityVelocity(veh, 0.0, 0.0, 0.0)
        SetEntityAngularVelocity(veh, 0.0, 0.0, 0.0)
    else
        SetEntityVelocity(veh, vx + 0.0, vy + 0.0, vz + 0.0)
        SetEntityAngularVelocity(veh, sx + 0.0, sy + 0.0, sz + 0.0)
    end
    SetVehicleSteeringAngle(veh, out[12] + 0.0)
    SetVehicleCurrentRpm(veh, out[13] + 0.0)
    -- After placing it (placing stops the wheels). Six wheels: the middle and back pairs turn alike. Each is the
    -- angle the game shows (TakeTrack.wheelAngle).
    for i = 0, play.wheels - 1 do
        local spin = i < 4 and out[TakeTrack.WHEELS + i] or out[TakeTrack.WHEELS + 2 + i % 2]
        SetVehicleWheelRotationSpeed(veh, i, TakeTrack.wheelAngle(spin) + 0.0)
    end
    flags(veh, play, out[14], play.force)
    play.force = false
end

-- A truck's trailer, as its take recorded it (client/director_takes.lua): the take's step carries the hitch and
-- release moments ({ { t, on, net } }) and the trailer plays its own recorded track beside it. A truck made with
-- its trailer by a card (Tows) is sent `tow` (the trailer's netId); its owner hitches it for a little while.

local TOW_REACH = 10.0     -- a trailer within this of the hitch is drawn onto it (ATTACH_VEHICLE_TO_TRAILER)
local TOW_TRY_MS = 10000   -- a truck's `tow` is tried this long after its version came

--- Hitch `trailer` to the car, or let go of the one it has (nil).
local function hitch(veh, trailer)
    if trailer then
        if DoesEntityExist(trailer) then AttachVehicleToTrailer(veh, trailer, TOW_REACH) end
    else
        DetachVehicleFromTrailer(veh)
    end
end

--- Is this trailer on the car's hitch now?
local function towing(veh, trailer)
    local has, t = GetVehicleTrailerVehicle(veh)
    return (has == true or has == 1) and t == trailer
end

--- A take's hitches up to time t (play.tow, in order: { t, on, net | veh }): each whose moment has come, once.
local function towTo(veh, play, t)
    local list = play.tow
    if not list then return end
    while play.towAt <= #list and list[play.towAt].t <= t do
        local e = list[play.towAt]
        play.towAt = play.towAt + 1
        hitch(veh, e.on and (e.veh or (e.net and vehFor(e.net))) or nil)
    end
end

--- A take step's hitches, in order of their moments: { { t, on, net } }, or nil.
local function towOf(list)
    if type(list) ~= 'table' or #list == 0 then return nil end
    local out = {}
    for _, e in ipairs(list) do
        if type(e) == 'table' and tonumber(e.t) then out[#out + 1] = { t = tonumber(e.t), on = e.on == true, net = e.net, veh = e.veh } end
    end
    table.sort(out, function(a, b) return a.t < b.t end)
    return #out > 0 and out or nil
end

--- While a take plays: a crash may crumple the car but not set it alight or stall it; no radio. Engine on unless the
--- drive leaves it to the tasks (`skip`). Kept driveable: whip's ignition makes a keyless car undriveable with
--- someone at the wheel, and GTA stops an undriveable car's engine.
local function crashProof(veh, skip)
    SetVehicleEngineCanDegrade(veh, false)
    SetVehicleExplodesOnHighExplosionDamage(veh, false)
    SetDisableVehiclePetrolTankFires(veh, true)
    SetVehRadioStation(veh, 'OFF')
    SetVehicleUndriveable(veh, false)
    if (skip or 0) & FLAG.engine == 0 then SetVehicleEngineOn(veh, true, true, false) end
end

--- The take over: a crash may stall, ignite and blow it up again.
local function crashProofOff(veh)
    SetVehicleEngineCanDegrade(veh, true)
    SetVehicleExplodesOnHighExplosionDamage(veh, true)
    SetDisableVehiclePetrolTankFires(veh, false)
end

-- Gear: GTA's gearbox does not move a car a take plays, so its gear says nothing. While a take plays the gear is
-- the take's (TakeTrack.gearOf), or worked out from speed when the take has none (Vehicles.speedGear).

local driving = {}       -- [car] = the take playing on it on this game (its `play`), while one does

--- The gear of the take playing on this car now: 1 and up.
local function gearNow(veh, play)
    local recorded = TakeTrack.gearOf(play.out[14])
    if recorded then return recorded end
    return Vehicles.speedGear(veh, play)
end

--- The take no longer plays on its car here: crashProofOff, and GTA's gearbox gets the gear it ended in.
local function takeDone(play)
    local veh = play.veh
    if driving[veh] ~= play then return end   -- (another take took the car: it has it now)
    driving[veh] = nil
    if not DoesEntityExist(veh) then return end
    crashProofOff(veh)
    if play.late then return end
    Vehicles.gearboxTo(veh, gearNow(veh, play))
end

--- One freeze, two reasons: the server's (w.held, hold below) and a take's countdown (w.takeHold). The car goes
--- free only when neither holds it. A car no longer this game's is not touched.
local function takeLetGo(veh, netId, w, play)
    if w.takeHold == play then w.takeHold = nil end
    local cur = watches[netId]
    if not (cur and (cur.held or cur.takeHold)) then FreezeEntityPosition(veh, false) end
end

--- Play a take on this car, frame by frame, while it is this game's and this job's.
local function playTake(netId, w, play)
    CreateThread(function()
        -- The server's time first (Clock.ready), or the take plays minutes off or is taken as over.
        if not Clock.synced() then
            Clock.ready(3000)
            if Clock.now() - play.startAt >= play.len then
                play.ended, play.late = true, true   -- (taken over after its end after all: left where it is)
                local veh = vehFor(netId)
                if mine(veh) then towTo(veh, play, play.len) end
                takeDone(play)
                return
            end
        end
        local held = false
        while true do
            local veh = vehFor(netId)
            if watches[netId] ~= w or w.play ~= play then
                -- Its job changed (or the car left and returned) during the countdown: its hold goes too.
                if held then
                    if mine(veh) then takeLetGo(veh, netId, w, play) elseif w.takeHold == play then w.takeHold = nil end
                end
                break
            end
            if not mine(veh) then
                if w.takeHold == play then w.takeHold = nil end
                break
            end
            local t = Clock.now() - play.startAt
            if t >= play.len then
                if not play.ended then
                    if not play.late then pose(veh, play, play.len, false) end
                    towTo(veh, play, play.len)
                    play.ended = true
                end
                if held then takeLetGo(veh, netId, w, play) end
                break
            end
            if t < 0 then
                if not held then
                    FreezeEntityPosition(veh, true)
                    held, w.takeHold = true, play
                end
                pose(veh, play, 0, true)
            else
                if held then takeLetGo(veh, netId, w, play); held = false end
                pose(veh, play, t, false)
                towTo(veh, play, t)
            end
            Wait(0)
        end
        takeDone(play)
    end)
end

STEP.take = function(veh, w, s)
    local keys = takeOf(s.p.take)
    if not keys then return { failed = true } end
    local play = { keys = keys, n = #keys // K, len = TakeTrack.length(keys), startAt = s.p.startAt or Clock.now(),
                   cur = 0, out = {}, flags = 0, force = true, warpNext = true, skip = leaveMask(s.p.leave),
                   wheels = GetVehicleNumberOfWheels(veh) or 0, tow = towOf(s.p.tow), towAt = 1 }
    -- Taken over after its end: done, never pulled back. Only once the server's time is read (Clock.synced);
    -- before that, playTake waits and asks again.
    if Clock.synced() and Clock.now() - play.startAt >= play.len then
        play.ended, play.late = true, true
        towTo(veh, play, play.len)
        return { take = play }
    end
    play.veh, driving[veh] = veh, play
    crashProof(veh, play.skip)
    w.play = play
    playTake(w.netId, w, play)
    return { take = play }
end

--- Every take asked for in one frame goes in one ask at its end (whip_core:server:takeWant), 64 at most.
local toAsk = nil
local function ask(id)
    if not toAsk then
        toAsk = {}
        SetTimeout(0, function()
            local list = toAsk
            toAsk = nil
            for i = 1, #list, 64 do
                TriggerServerEvent('whip_core:server:takeWant', table.move(list, i, math.min(#list, i + 63), 1, {}))
            end
        end)
    end
    toAsk[#toAsk + 1] = id
end

--- Asks for the takes a job plays that this game lacks; asks again after TAKE_ASK_AGAIN_MS if one is still missing.
local TAKE_ASK_AGAIN_MS = 8000
local function missingTakes(job)
    local missing = false
    for _, s in ipairs(job and job.list or {}) do
        local id = s.t == 'take' and s.p and s.p.take
        if id and not takes[id] then
            missing = true
            if GetGameTimer() - (asked[id] or -TAKE_ASK_AGAIN_MS) >= TAKE_ASK_AGAIN_MS then
                asked[id] = GetGameTimer()
                ask(id)
            end
        end
    end
    return missing
end

--- Is every seat empty?
local function empty(veh)
    for s = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
        if not IsVehicleSeatFree(veh, s) then return false end
    end
    return true
end

local function satStep(veh, _, s, left) return DirectorTaskSteps.run(veh, 'vehicle', s, left) end

--- What the last job's timed steps left going (a brake, flashing lights, the horn), ended: a new job means their slot is
--- over, and no job means their list was stopped (a Stop Tasks), which they must not outlast.
local function endTimed(veh, w)
    if w.brakeUntil then
        w.brakeUntil = nil
        if veh then SetVehicleHandbrake(veh, false) end
    end
    if w.flash then
        w.flash = nil
        if veh then SetVehicleLights(veh, 0) end
    end
    w.horn = nil   -- (it stops by itself, sounded no more)
end

local function runJob(veh, w)
    local job = w.data.job
    if not job or w.ran == job.id then return end
    endTimed(veh, w)
    w.ran, w.look, w.saidAt, w.speed, w.play = job.id, nil, nil, nil, nil
    local since = tonumber(job.since) or 0
    local list = job.list or {}
    for i, s in ipairs(list) do
        -- (Another resource's step, Whip.task: played by its own code, client/director_tasks.lua.)
        local run = STEP[s.t] or (DirectorTaskSteps.isSatellite(s.t) and satStep) or nil
        if run and not (since > 0 and (s.timing == 'instant' or s.once)) then
            local left = math.max(100, (s.ms or s.giveUpMs or 10000) - (i == #list and since or 0))
            local ok, look = pcall(run, veh, w, s, left)
            if not ok then
                print(('[whip_core:actors] car %s: task %s failed here: %s'):format(tostring(w.netId), tostring(s.t), tostring(look)))
            elseif i == #list and s.timing == 'until' then
                w.look = look or {}
            end
        end
    end
end

--- Frozen while the server says so; let go once it stops, unless a take's countdown holds it (takeLetGo). A car
--- it never froze is left as it is.
local function hold(veh, w)
    local want = w.data.frozen == true or (w.data.job ~= nil and w.data.job.frozen == true)
    if want then
        w.held = true
        if not IsEntityPositionFrozen(veh) then FreezeEntityPosition(veh, true) end
    elseif w.held then
        w.held = false
        if not w.takeHold then FreezeEntityPosition(veh, false) end
    end
end

--- One look at a car this game runs: hold, speed, brake, trailer, flashing lights, job done. Answers when it wants
--- the next (a tenth of a second while holding a speed, else a quarter), or nil once this game no longer runs it.
local function lookAt(netId, w, now)
    local veh = vehFor(netId)
    if not mine(veh) then return nil end
    hold(veh, w)
    if w.speed then
        if now < w.speed.untilAt then SetVehicleForwardSpeed(veh, w.speed.mps) else w.speed = nil end
    end
    if w.brakeUntil and now >= w.brakeUntil then
        w.brakeUntil = nil
        SetVehicleHandbrake(veh, false)
    end
    -- Its trailer (its page's Tows), while a take does not say otherwise.
    if w.data.tow and not w.play and now < (w.towUntil or 0) then
        local trailer = vehFor(w.data.tow)
        if trailer and not towing(veh, trailer) then hitch(veh, trailer) end
    end
    -- Flash the Lights: toggled at each look for its time.
    if w.flash then
        if now >= w.flash.untilAt then
            w.flash = nil
            SetVehicleLights(veh, 0)
        else
            w.flash.on = not w.flash.on
            SetVehicleLights(veh, w.flash.on and 2 or 1)
        end
    end
    -- Sound the Horn: sounded again at each look for its time.
    if w.horn then
        if now >= w.horn.untilAt then w.horn = nil
        else StartVehicleHorn(veh, math.floor(math.min(HORN_MS, w.horn.untilAt - now)), HORN, false) end
    end
    local job = w.data.job
    local look = w.look
    local how = look and ((look.sat and DirectorTaskSteps.done(veh, look))
        or (look.empty and empty(veh)) and 'done'
        or (look.take and (look.take.ended or (Clock.synced() and Clock.now() - look.take.startAt >= look.take.len))) and 'done'
        or look.failed and 'failed') or nil
    if job and how and now >= (w.saidAt or 0) then
        w.saidAt = now + SAY_MS
        TriggerServerEvent('whip_core:server:actorJob', w.id, netId, job.id, how)
    end
    return w.speed and 100 or 250
end

--- While this game runs cars: one loop looks at each when due, ending with the last. One whose look fails is let go.
local watching = false
local function watch()
    if watching then return end
    watching = true
    CreateThread(function()
        while next(watches) do
            local now = GetGameTimer()
            local soonest = 250
            local ids = {}
            for netId in pairs(watches) do ids[#ids + 1] = netId end
            for _, netId in ipairs(ids) do
                local w = watches[netId]
                if w and now >= (w.dueAt or 0) then
                    local ok, nextMs = pcall(lookAt, netId, w, now)
                    if not ok then
                        print(('[whip_core:actors] car %s: its watch failed and was let go: %s'):format(tostring(netId), tostring(nextMs)))
                    end
                    if not ok or not nextMs then
                        if watches[netId] == w then watches[netId] = nil end
                    else
                        w.dueAt = now + nextMs
                    end
                end
                if w and watches[netId] == w then soonest = math.min(soonest, math.max(0, (w.dueAt or 0) - now)) end
            end
            Wait(soonest)
        end
        watching = false
    end)
end

local waiting = {}   -- [netId] = the last version sent while its take's samples were on their way (held: frozen meanwhile)

local function applyVersion(id, netId, ver, data)
    local veh = vehFor(netId)
    -- Not here yet, or not ours: the server sends it again (to its new owner).
    if not mine(veh) then waiting[netId] = nil return end
    -- A take this game lacks is asked for and not said applied until it is here; the server's freeze holds meanwhile.
    if missingTakes(data.job) then
        local want = data.frozen == true or (data.job ~= nil and data.job.frozen == true)
        if want and not IsEntityPositionFrozen(veh) then FreezeEntityPosition(veh, true) end
        waiting[netId] = { id = id, ver = ver, data = data, held = want or (waiting[netId] ~= nil and waiting[netId].held) }
        return
    end
    local was = waiting[netId]
    waiting[netId] = nil
    local w = watches[netId]
    local fresh = (w == nil)
    if fresh then w = { netId = netId }; watches[netId] = w end
    w.id, w.ver, w.data = id, ver, data
    -- (Frozen while it waited: the server's hold, let go by hold() below.)
    if was and was.held then w.held = true end
    -- (A trailer to hitch: tried for a while after the car is new to this game.)
    if data.tow ~= w.towNet or fresh then w.towNet, w.towUntil = data.tow, GetGameTimer() + TOW_TRY_MS end
    if not data.job then
        endTimed(veh, w)
        w.ran, w.look, w.speed, w.play = nil, nil, nil, nil
    end
    -- A car new to this game: what its earlier steps left set (lights, siren: server/actors.lua's state) is
    -- set again first, then its job's own steps.
    if fresh and type(data.state) == 'table' then
        for _, s in pairs(data.state) do
            local fn = type(s) == 'table' and STEP[s.t]
            if fn and type(s.p) == 'table' then
                local ok, err = pcall(fn, veh, w, s)
                if not ok then print(('[whip_core:actors] car %s: its %s again failed: %s'):format(tostring(netId), tostring(s.t), tostring(err))) end
            end
        end
    end
    runJob(veh, w)
    hold(veh, w)
    if fresh then watch() end
    TriggerServerEvent('whip_core:server:actorApplied', id, netId, ver)
end

RegisterNetEvent('whip_core:client:actorJob', function(id, netId, ver, data)
    if type(data) ~= 'table' or type(netId) ~= 'number' then return end
    applyVersion(id, netId, ver, data)
end)

-- For the Director's own use: a take watched in the editor (client/director_takes.lua)

--- The Director's preview in the world builder (client/director_preview.lua): the steps that need no run state
--- (a step's carPreview: teleport, siren, health, everyone out, doors, windows, lights, indicators, engine, tyres,
--- roof, dirt), on a car of this game's own, and whether its seats are empty. Steps that act over time are the
--- preview's own; a fire, an alarm and a lock are a run's alone.
ActorSteps = {
    run = function(veh, s, left)
        local fn = DirectorSteps.is(s.t, 'carPreview') and STEP[s.t] or nil
        if not fn then return nil end
        return fn(veh, {}, s, left)
    end,
    empty = empty,
}

TakePlayer = {}

--- A take's samples: here already, or asked for and waited on (30 s at most). Waits: a thread.
function TakePlayer.fetch(id)
    if takes[id] then return takeOf(id) end
    local untilAt = GetGameTimer() + 30000
    while not takes[id] and GetGameTimer() < untilAt do
        missingTakes({ list = { { t = 'take', p = { take = id } } } })
        Wait(100)
    end
    return takes[id]
end

--- Keep samples just recorded, so watching them needs no server trip.
function TakePlayer.keep(id, samples) keepTake(id, samples) end

--- Is a take playing on this car on this game now?
function TakePlayer.on(veh) return driving[veh] ~= nil end

--- The gear of the take playing on this car on this game now, or nil with none playing.
function TakePlayer.gearOn(veh)
    local play = driving[veh]
    return play and gearNow(veh, play) or nil
end

--- Where a take starts: x, y, z, heading.
function TakePlayer.start(samples)
    return samples[2], samples[3], samples[4], TakeTrack.heading(samples[5], samples[6], samples[7], samples[8])
end

--- Drive a car of this game's own (not networked) along a take from now until its end or until still() says
--- stop. Waits: a thread. `opts`: { startAt = GetGameTimer() moment it starts (cars driven together share one),
--- tow = { { t, on, veh } } (its trailer's hitches), leave = what it leaves to the car's tasks
--- ({ lights = true, ... }: DirectorSteps.leftByDrives) }.
function TakePlayer.drive(veh, samples, still, opts)
    opts = type(opts) == 'table' and opts or {}
    local play = { keys = samples, n = #samples // K, len = TakeTrack.length(samples), startAt = opts.startAt or GetGameTimer(),
                   cur = 0, out = {}, flags = 0, force = true, warpNext = true, wheels = GetVehicleNumberOfWheels(veh) or 0,
                   tow = towOf(opts.tow), towAt = 1, skip = leaveMask(opts.leave) }
    play.veh, driving[veh] = veh, play
    crashProof(veh, play.skip)
    while DoesEntityExist(veh) and still() do
        local t = GetGameTimer() - play.startAt
        if t >= play.len then
            pose(veh, play, play.len, false)
            towTo(veh, play, play.len)
            break
        end
        pose(veh, play, math.max(0, t), false)
        towTo(veh, play, t)
        Wait(0)
    end
    takeDone(play)
end

--- Hitch a trailer of this game's own to a car of its own, or let go (nil): the recorder's (a truck that starts
--- with its trailer on).
TakePlayer.hitch = hitch

--- The trailer on a car's hitch now, or nil.
function TakePlayer.trailerOf(veh)
    local has, t = GetVehicleTrailerVehicle(veh)
    if (has == true or has == 1) and t and t ~= 0 and DoesEntityExist(t) then return t end
    return nil
end

--- A take's samples arrive packed (TakeTrack.pack): kept, and whatever waited for them goes on.
RegisterNetEvent('whip_core:client:take', function(id, packed)
    if type(id) ~= 'number' then return end
    -- (Here: the server's next send to this game may go.)
    TriggerServerEvent('whip_core:server:takeGot', id)
    local samples = TakeTrack.unpack(packed)
    if not samples or not TakeTrack.check(samples) then return end
    keepTake(id, samples)
    for netId, v in pairs(waiting) do applyVersion(v.id, netId, v.ver, v.data) end
end)

--- The game a take plays on (server/actors.lua's pin): take the car and keep it, or let it go again.
RegisterNetEvent('whip_core:client:actorPin', function(_, netId, on)
    if type(netId) ~= 'number' then return end
    CreateThread(function()
        local veh = vehFor(netId)
        if not veh then return end
        if on then
            if Vehicles.takeControl(veh, { attempts = 3, wait = 300 }) then SetNetworkIdCanMigrate(netId, false) end
        elseif mine(veh) then
            SetNetworkIdCanMigrate(netId, true)
        end
    end)
end)
