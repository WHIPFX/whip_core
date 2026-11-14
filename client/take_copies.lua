-- ============================================
-- TAKE COPIES — a recorded drive played on this game's own copy of the car (Experimental recorded drives sync)
-- ============================================
--
-- A Director car playing a take is driven by one game, the take's PIN (server/actors.lua). Every other game sees it as
-- the network sends it: late (half the driver's ping, half this game's, the gap between updates, and GTA drawing a
-- remote car a little in the past to blend it), and, when an update is late, guessed and then put right. With
-- Config.ExperimentalDriveSync on, the server tells every game in the car's world which take the car plays and from
-- when on the shared clock (whip_core:client:takeShow), and a take is only where the car is at each moment: so every
-- game but the driver's plays it itself, on a COPY of the car only it has, smooth and in the same place on every
-- screen.
--
--   the copy      made while the real car is here and near (COPY_RANGE), where the take is now (a game that comes in
--                 late starts part-way), dressed as the real one (GetVehicleProperties, and whip_core:vehicle:copied for
--                 what other resources draw on a car: whip_autos' stance and engine sound), the peds in it and the NPCs
--                 riding on it cloned in their places. A take's trailers are copies too, hitched when the take did
--   the real one  hidden on this screen every frame with the peds in and on it, and not solid against this player:
--                 it still drives underneath, so what it is stays real for everyone
--   hits          damage this player does to the copy, or to a rider's clone, goes to the server
--                 (whip_core:server:takeCopyHit), which has the owner of the real one take it
--   its state     the real car's burst tyres, engine and body health, and a rider's death show on the copy; and what
--                 the drive leaves to the car's tasks (the show's `leave`: its lights, indicators, siren or engine as
--                 a Lights task set them) is the real car's, not the recording's
--   the end       the show over, the real car gone or wrecked, this game the driver now, or this player in the real
--                 car: the copy goes once the real car is close to it (END_MAX_MS at most), and the real one shows
--
-- No Wait(0) without a copy: a quarter-second look while any show is going, nothing with none.

local COPY_RANGE = 350.0    -- metres from the camera: further, no copy
local LOOK_MS    = 250
local END_CLOSE  = 2.0      -- the real car this close to its copy: the copy goes
local END_MAX_MS = 1500
local MODEL_MS   = 2000

local shows = {}            -- [netId] = { take, startAt, pin, tow, leave, samples, fetching, copy, over, done }
local looping = false

local function myId() return GetPlayerServerId(PlayerId()) end

local function realOf(netId) return DirectorKit.entityOfNet(netId, 2) end

-- ---- a copy ----

local function deleteCopy(c)
    if not c then return end
    for _, r in ipairs(c.riders) do
        if DoesEntityExist(r.clone) then SetEntityAsMissionEntity(r.clone, true, true) DeleteEntity(r.clone) end
    end
    if DoesEntityExist(c.veh) then SetEntityAsMissionEntity(c.veh, true, true) DeleteEntity(c.veh) end
end

--- A clone of a ped of the real car, this game's own: in its seat, or on the copy where it rides on the real one.
local function cloneRider(ped, veh, seat, real)
    local clone = ClonePed(ped, false, false, true)
    if not clone or clone == 0 then return nil end
    SetEntityAsMissionEntity(clone, true, true)
    SetBlockingOfNonTemporaryEvents(clone, true)
    if seat then
        SetPedIntoVehicle(clone, veh, seat)
    else
        local at = GetEntityCoords(ped)
        local off = GetOffsetFromEntityGivenWorldCoords(real, at.x, at.y, at.z)
        AttachEntityToEntity(clone, veh, 0, off.x, off.y, off.z, 0.0, 0.0, GetEntityHeading(ped) - GetEntityHeading(real),
            false, false, false, true, 2, true)
    end
    return { ped = ped, clone = clone, seat = seat, net = NetworkGetEntityIsNetworked(ped) and PedToNet(ped) or nil,
             health = GetEntityHealth(clone) }
end

--- The copy's riders as the real car's are now (each look): one sat or got on since is cloned in its place, one
--- that got out or off goes (its clone deleted, the real one no longer hidden). NPCs on it looked for once a second.
local function syncRiders(c)
    local keep = {}
    for _, r in ipairs(c.riders) do
        local still = DoesEntityExist(r.ped) and DoesEntityExist(r.clone)
            and (r.seat and GetPedInVehicleSeat(c.real, r.seat) == r.ped or (not r.seat and GetEntityAttachedTo(r.ped) == c.real))
        if still then keep[#keep + 1] = r
        elseif DoesEntityExist(r.clone) then SetEntityAsMissionEntity(r.clone, true, true) DeleteEntity(r.clone) end
    end
    c.riders = keep
    local has = {}
    for _, r in ipairs(keep) do has[r.ped] = true end
    for seat = -1, GetVehicleMaxNumberOfPassengers(c.real) - 1 do
        local ped = GetPedInVehicleSeat(c.real, seat)
        if ped ~= 0 and DoesEntityExist(ped) and not has[ped] then
            c.riders[#c.riders + 1] = cloneRider(ped, c.veh, seat, c.real)
            has[ped] = true
        end
    end
    local now = GetGameTimer()
    if now >= (c.onAt or 0) then
        c.onAt = now + 1000
        for _, ped in ipairs(GetGamePool('CPed')) do
            if not has[ped] and GetEntityAttachedTo(ped) == c.real and not IsPedInAnyVehicle(ped, false) then
                c.riders[#c.riders + 1] = cloneRider(ped, c.veh, nil, c.real)
            end
        end
    end
end

--- The copy of the real car, where the take starts (its drive puts it where the take is now), dressed as it.
local function makeCopy(s, real)
    local model = GetEntityModel(real)
    if not LoadModel(model, MODEL_MS) then return nil end
    local x, y, z, h = TakePlayer.start(s.samples)
    local veh = CreateVehicle(model, x, y, z, h, false, false)
    SetModelAsNoLongerNeeded(model)
    if not veh or veh == 0 then return nil end
    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleProperties(veh, GetVehicleProperties(real))
    SetVehicleEngineOn(veh, true, true, false)
    WhipEmit('whip_core:vehicle:copied', { entity = veh, of = real })
    local c = { veh = veh, real = real, riders = {}, tyres = {} }
    syncRiders(c)
    c.engine, c.body = GetVehicleEngineHealth(veh), GetVehicleBodyHealth(veh)
    return c
end

--- Its drive, from the take's moment on the shared clock (Clock.now: the server's), hitched to its trailers' copies.
local function drive(netId, s)
    local c = s.copy
    local startAt = GetGameTimer() - (Clock.now() - s.startAt)
    local tow = {}
    for _, e in ipairs(type(s.tow) == 'table' and s.tow or {}) do
        local other = type(e) == 'table' and e.net and shows[e.net]
        if other and other.copy then tow[#tow + 1] = { t = tonumber(e.t) or 0, on = e.on == true, veh = other.copy.veh } end
    end
    local still = function() return shows[netId] == s and s.copy == c and not c.ending end
    c.leave = type(s.leave) == 'table' and s.leave or nil
    CreateThread(function() TakePlayer.drive(c.veh, s.samples, still, { startAt = startAt, tow = tow, leave = c.leave }) end)
end

-- ---- each look ----

--- Damage this player did to the copy or a rider's clone since the last look, sent to be done to the real ones.
local function hits(netId, c)
    local me = PlayerPedId()
    local myCar = GetVehiclePedIsIn(me, false)
    local function byMe(e)
        return HasEntityBeenDamagedByEntity(e, me, true) or (myCar ~= 0 and HasEntityBeenDamagedByEntity(e, myCar, true))
    end
    local out = nil
    local e, b = GetVehicleEngineHealth(c.veh), GetVehicleBodyHealth(c.veh)
    if byMe(c.veh) then
        local tyres = {}
        for i = 0, 7 do
            if IsVehicleTyreBurst(c.veh, i, false) and not c.tyres[i] then tyres[#tyres + 1] = i end
        end
        local de, db = math.max(0.0, c.engine - e), math.max(0.0, c.body - b)
        if de > 0 or db > 0 or #tyres > 0 then out = { engine = de, body = db, tyres = tyres } end
        ClearEntityLastDamageEntity(c.veh)
    end
    c.engine, c.body = e, b
    for i = 0, 7 do
        if IsVehicleTyreBurst(c.veh, i, false) then c.tyres[i] = true end
    end
    for _, r in ipairs(c.riders) do
        if DoesEntityExist(r.clone) then
            local now = GetEntityHealth(r.clone)
            if r.net and now < r.health and byMe(r.clone) then
                out = out or {}
                out.peds = out.peds or {}
                out.peds[tostring(r.net)] = r.health - now
                ClearEntityLastDamageEntity(r.clone)
            end
            r.health = now
        end
    end
    if out then TriggerServerEvent('whip_core:server:takeCopyHit', netId, out) end
end

--- The real car's state on the copy: burst tyres, engine and body health (only ever down), a rider's death.
local function mirror(c)
    local real, veh = c.real, c.veh
    for i = 0, 7 do
        if IsVehicleTyreBurst(real, i, false) and not IsVehicleTyreBurst(veh, i, false) then
            SetVehicleTyreBurst(veh, i, false, 1000.0)
            c.tyres[i] = true
        end
    end
    local re, rb = GetVehicleEngineHealth(real), GetVehicleBodyHealth(real)
    if re < GetVehicleEngineHealth(veh) then SetVehicleEngineHealth(veh, re + 0.0) end
    if rb < GetVehicleBodyHealth(veh) then SetVehicleBodyHealth(veh, rb + 0.0) end
    c.engine, c.body = GetVehicleEngineHealth(veh), GetVehicleBodyHealth(veh)
    for _, r in ipairs(c.riders) do
        if DoesEntityExist(r.clone) and DoesEntityExist(r.ped) and IsPedDeadOrDying(r.ped, true)
            and not IsPedDeadOrDying(r.clone, true) then
            SetEntityHealth(r.clone, 0)
        end
        if DoesEntityExist(r.clone) then r.health = GetEntityHealth(r.clone) end
    end
    -- What the drive leaves to the car's tasks: as the real one has it (set on the copy when it changes).
    local leave = c.leave
    if not leave then return end
    local was = c.left or {}
    local now = {}
    if leave.lights then
        local _, on, high = GetVehicleLightsState(real)
        now.lights, now.high = on == true or on == 1, high == true or high == 1
        if now.lights ~= was.lights then SetVehicleLights(veh, now.lights and 2 or 1) end
        if now.high ~= was.high then SetVehicleFullbeam(veh, now.high) end
    end
    if leave.indicators then
        now.ind = GetVehicleIndicatorLights(real)   -- (0 none, 1 left, 2 right, 3 both)
        if now.ind ~= was.ind then
            SetVehicleIndicatorLights(veh, 1, now.ind == 1 or now.ind == 3)
            SetVehicleIndicatorLights(veh, 0, now.ind == 2 or now.ind == 3)
        end
    end
    if leave.siren then
        local on = IsVehicleSirenOn(real)   -- (a BOOL native: 1 or false here)
        now.siren = on == true or on == 1
        if now.siren ~= was.siren then SetVehicleSiren(veh, now.siren) end
    end
    if leave.engine then
        now.engine = GetIsVehicleEngineRunning(real) == true or GetIsVehicleEngineRunning(real) == 1
        if now.engine ~= was.engine then SetVehicleEngineOn(veh, now.engine, true, true) end
    end
    c.left = now
end

--- A car people stand on while it moves (its "Players and NPCs can stand on it": client/director_standon.lua). Never
--- copied: the copy is a car of this game's alone, ahead of the real one by a ping's worth of road, and whoever stood
--- on the real one would fall through it. The cars that carry it are kept by whip's vehicle data watcher as their data
--- comes and goes (as client/director_standon.lua keeps them), not read from each car's whole data block.
local standOnCars = {}
VehicleData.watch('directorStandOn', {
    id = 'takeCopies',
    onGained = function(entity, value) standOnCars[entity] = value == true or nil end,
    onLost = function(entity) standOnCars[entity] = nil end,
})
local function standOn(veh) return standOnCars[veh] == true end

--- Should this game show its own copy of the show's car now? And is that for good (`done`: not again this show)?
local function wanted(s, real)
    if s.over then return false end
    if s.pin == myId() then return false, true end                    -- this game drives the real one
    if not real then return false end                                 -- not here (out of range of the network)
    if standOn(real) then return false, true end                      -- people stand on the real one
    if IsEntityDead(real) then return false, true end                 -- wrecked: the real one shows
    if GetVehiclePedIsIn(PlayerPedId(), false) == real then return false, true end
    if not s.samples then return false end
    -- (Not before the server's time is read: placed by a wrong one, the copy would be minutes off.)
    if not Clock.synced() then Clock.sync() return false end
    if Clock.now() > s.startAt + TakeTrack.length(s.samples) + 10000 then return false, true end
    return #(GetFinalRenderedCamCoord() - GetEntityCoords(real)) <= COPY_RANGE
end

local function look()
    local started = {}
    for netId, s in pairs(shows) do
        local real = realOf(netId)
        if not s.samples and not s.fetching and not s.over then
            s.fetching = true
            CreateThread(function()
                s.samples = TakePlayer.fetch(s.take)
                s.fetching = false
            end)
        end
        local want, forGood = wanted(s, real)
        if forGood then s.done = true end
        local c = s.copy
        if c then
            if want and not s.done and real == c.real and DoesEntityExist(c.veh) then
                syncRiders(c)
                hits(netId, c)
                mirror(c)
            elseif not c.ending then
                c.ending = GetGameTimer()
            end
            if c.ending then
                local close = real and DoesEntityExist(c.veh) and #(GetEntityCoords(real) - GetEntityCoords(c.veh)) <= END_CLOSE
                if close or not real or GetGameTimer() - c.ending >= END_MAX_MS then
                    deleteCopy(c)
                    s.copy = nil
                end
            end
        elseif want and not s.done then
            s.copy = makeCopy(s, real)
            if s.copy then started[#started + 1] = netId end
        end
        if s.over and not s.copy then shows[netId] = nil end
    end
    -- (Driven after every copy of this look is made: a truck's trailer copy, made with it, is there to hitch.)
    for _, netId in ipairs(started) do drive(netId, shows[netId]) end
end

--- The real cars (and the peds in and on them) hidden on this screen, and not solid against this player. Every frame.
local function hide()
    local me = PlayerPedId()
    local myCar = GetVehiclePedIsIn(me, false)
    for _, s in pairs(shows) do
        local c = s.copy
        if c and DoesEntityExist(c.real) then
            SetEntityLocallyInvisible(c.real)
            SetEntityNoCollisionEntity(c.real, me, true)
            if myCar ~= 0 then SetEntityNoCollisionEntity(c.real, myCar, true) end
            SetEntityNoCollisionEntity(c.real, c.veh, true)
            for _, r in ipairs(c.riders) do
                if DoesEntityExist(r.ped) then SetEntityLocallyInvisible(r.ped) end
            end
        end
    end
end

local function anyCopy()
    for _, s in pairs(shows) do if s.copy then return true end end
    return false
end

local function startLoop()
    if looping then return end
    looping = true
    CreateThread(function()
        local lookAt = 0
        while next(shows) do
            local now = GetGameTimer()
            if now >= lookAt then
                lookAt = now + LOOK_MS
                local ok, err = pcall(look)
                if not ok then print('[whip_core:take_copies] ' .. tostring(err)) end
            end
            if anyCopy() then
                hide()
                Wait(0)
            else
                Wait(LOOK_MS)
            end
        end
        looping = false
    end)
end

-- ---- from the server ----

--- A car's show: { take, startAt, pin, tow }, or false when it is over.
RegisterNetEvent('whip_core:client:takeShow', function(netId, show)
    if type(netId) ~= 'number' then return end
    local s = shows[netId]
    if type(show) ~= 'table' then
        if s then s.over = true end
        return
    end
    -- The same take from the same moment (its driver changed): kept, with the new driver (this game, no longer it,
    -- may want a copy now).
    if s and not s.over and s.take == math.tointeger(tonumber(show.take)) and s.startAt == tonumber(show.startAt) then
        s.pin, s.tow, s.leave, s.done = tonumber(show.pin), show.tow, show.leave, nil
        return
    end
    if s and s.copy then deleteCopy(s.copy) end
    shows[netId] = { take = math.tointeger(tonumber(show.take)), startAt = tonumber(show.startAt) or 0,
                     pin = tonumber(show.pin), tow = show.tow, leave = show.leave }
    startLoop()
end)

--- Damage a player did to their copy (or a rider's clone): done here to the real one, which this game owns.
RegisterNetEvent('whip_core:client:takeCopyHit', function(netId, hit)
    if type(hit) ~= 'table' then return end
    local e = DirectorKit.entityOfNet(netId)
    if not DirectorKit.mine(e) then return end
    if hit.ped then
        -- (Only whip's NPCs, as the server sends: never a player's ped, whatever arrives.)
        local p = GetEntityType(e) == 1 and IsPedAPlayer(e)
        if GetEntityType(e) == 1 and not (p == true or p == 1) then
            ApplyDamageToPed(e, math.floor(math.max(0, math.min(100, tonumber(hit.ped) or 0))), false)
        end
        return
    end
    if GetEntityType(e) ~= 2 then return end
    -- (Never below nothing: a copy's hit can stop an engine, never set it alight.)
    if (tonumber(hit.engine) or 0) > 0 then SetVehicleEngineHealth(e, math.max(0.0, GetVehicleEngineHealth(e) - hit.engine)) end
    if (tonumber(hit.body) or 0) > 0 then SetVehicleBodyHealth(e, math.max(0.0, GetVehicleBodyHealth(e) - hit.body)) end
    for _, i in ipairs(type(hit.tyres) == 'table' and hit.tyres or {}) do SetVehicleTyreBurst(e, i, false, 1000.0) end
end)

-- A game come in late: the shows going.
local function askShows() TriggerServerEvent('whip_core:server:takeShowsWant') end
AddEventHandler('whip_core:player:loaded', askShows)
CreateThread(function()
    Wait(2000)
    if PlayerLoaded then askShows() end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, s in pairs(shows) do deleteCopy(s.copy) end
end)
