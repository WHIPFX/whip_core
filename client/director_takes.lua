-- ============================================
-- DIRECTOR — recording a car's take, and watching one (the car's page: Takes)
-- ============================================
--
-- RECORD A TAKE. The editor steps out of the way (DirectorScreen.aside) and this game makes its own copy of the
-- car (not networked: only the recording is the server's) where the car is placed, its riders in their seats,
-- the player at the wheel. Then, as whip_scenes' recorder does:
--
--   count    the car held on its spot, engine running, 3 2 1
--   rec      every frame of the car read (shared/take_track.lua keeps only what playback needs), up to MAX_S
--   held     the time ran out, or the car is gone: Save what there is, or Retry
--   saving   sent to the server (a latent event: whip_core:server:takeSave), waiting for its answer
--
-- F10 saves, F11 starts again from the spot (the car mended), F4 throws it away (keys a player can rebind).
-- Saved, the take joins the car's list on its page (directorTakeSaved); the scenario's own Save keeps that
-- list. Whatever happens, the copy goes and the player is put back where they were, and the editor comes back.
--
-- THE OTHER CARS. The scenario's other cars with takes (the page says which take each plays: html/js/director/app.js
-- otherTakes) are copies of this game's own too, with their riders, held where their takes start through the
-- count and driving them from the GO, as the run will play them side by side: a race or a near miss is driven
-- against them. F11 puts them back with the car.
--
-- THE PARKED ONES AND TRAILERS. The scenario's other placed cars with no take (the page's `parked`: a trailer, a car
-- in the way) stand where they are placed, held through the count and free from the GO. Backed into, a trailer hooks on
-- as GTA hooks one; the car's own trailer (its page's Tows) is hitched before the count. Each moment one of them is
-- hitched or let go is kept ({ t, w, on }), and so is every frame of each one: a trailer the car hitched is saved as a
-- take of its own (its own placed thing's), beside the car's, so a run plays it where it went, not as GTA would drag it
-- (server/director/nodes_tasks.lua). The car's take keeps both: { tow = { tracks = { [trailer] = take id }, events } }.
--
-- WATCH IT. The take driven on a copy of the car, the player riding in the passenger seat, then put back; its trailers'
-- own tracks driven beside it, hitched and let go when they were.
--
-- THEIR LOOKS. Every copy here is dressed as a run makes its car (dress: the world builder's own builderCopy event, so
-- whip_autos puts on a car's Whiplash look); the one the player drives is `driven`, its engine, handling and drivetrain
-- counting too, so the drive is recorded as the car a run makes would go.
--
-- What is on screen while recording is the page's (html/js/director/app.js: directorRec): the time, the keys.
--
-- RIDING ALONG, the run's own car at the wheel while a card plays its take, is at the end of this file.

local COUNT_MS = 3000
local MAX_S    = 180
local SAVE_BPS = 1000000
local SAVE_WAIT_MS = 20000
local SLOW_BYTES_PER_MS = 20   -- the wait grows by the time a 20 KB/s connection takes to send the take
local HUD_MS   = 100
local OTHERS_MAX = 8
local PARKED_MAX = 8

---@class TakeRecording
---@field key string
---@field wid string
---@field model string
---@field label string
---@field start table
---@field veh integer
---@field peds integer[]
---@field others table[]
---@field parked table[]
---@field tow? string
---@field back table
---@field reopen? string
---@field run? integer
---@field phase? string
---@field count? integer
---@field buf? table
---@field t0? integer
---@field t? integer
---@field why? string
---@field hitched? string
---@field towEvents? table[]
---@field saves? { list: table[], byToken: table }
---@field ask? integer
---@field keys? table
---@field hudAt? integer

---@type TakeRecording|nil
local R = nil        -- the recording: { phase, run, key, wid, model, label, start, veh, peds, others, parked, tow, hitched,
                     -- towEvents, buf, t0, t, ask, back, reopen, why, saves }; others = { { veh, peds, samples, at =
                     -- { x, y, z, heading }, label } }; parked = { { veh, wid, model, at, buf } }; saves = { [token] =
                     -- { wid (nil: the car's own), buf, keys, id, ms } } while a Save is answered
local runs, asks = 0, 0
local keysMade = false
local watching = false
local watchRun = 0       -- each watch's number: a watch ended by a death or a logout (abandon) is not its own any more
local starting = false   -- a recording being set up (its other cars' takes on their way)
local setupGen = 0       -- bumped by abandon: a recording set up before it does not start

--- [token] = true: a drive whose save went and was not answered, let go (F11, F4, a death). Its answer, when it
--- comes, has the server delete the take it wrote: nothing will ever name it (whip_core:server:takeForget).
local unanswered = {}
local function letGoOfSave(buf)
    if buf and buf.token and buf.sent and not buf.answered then unanswered[buf.token] = true end
end

local FLAG = TakeTrack.FLAG
local INPUT_VEH_BRAKE = 72

local function yes(v) return v ~= nil and v ~= false and v ~= 0 end

local function hud(force)
    if not R then SendNUIMessage({ action = 'directorRec', off = true }) return end
    local now = GetGameTimer()
    if not force and now < (R.hudAt or 0) then return end
    R.hudAt = now + HUD_MS
    SendNUIMessage({ action = 'directorRec', phase = R.phase, ms = R.t or 0, max = MAX_S * 1000, label = R.label,
                     count = R.count, why = R.why })
end

--- One frame of the car, as a take keeps it (whip_scenes' sample), into the drive `rec` (its wheels counted on there).
local function sample(veh, t, rec)
    local c = GetEntityCoords(veh)
    local qx, qy, qz, qw = GetEntityQuaternion(veh)
    local v = GetEntityVelocity(veh)
    local fl = 0
    local w = { 0.0, 0.0, 0.0, 0.0 }
    local braking = false
    for i = 0, math.min(GetVehicleNumberOfWheels(veh) or 0, 4) - 1 do
        -- (The game's angle, -pi to pi: counted on through its turns, so a steady spin is a line: TakeTrack.unwrap.)
        w[i + 1] = TakeTrack.unwrap(rec, i, GetVehicleWheelRotationSpeed(veh, i) or 0, t)
        if (GetVehicleWheelBrakePressure(veh, i) or 0) > 0.05 then braking = true end
    end
    if not braking and yes(IsControlPressed(0, INPUT_VEH_BRAKE)) and GetEntitySpeedVector(veh, true).y > 0.5 then
        braking = true
    end
    if braking then fl = fl | FLAG.brake end
    if yes(GetVehicleHandbrake(veh)) then fl = fl | FLAG.handbrake end
    if yes(IsHornActive(veh)) then fl = fl | FLAG.horn end
    if yes(IsVehicleSirenOn(veh)) then fl = fl | FLAG.siren end
    local _, on, high = GetVehicleLightsState(veh)
    if yes(on) then fl = fl | FLAG.lights end
    if yes(high) then fl = fl | FLAG.fullbeam end
    local ind = GetVehicleIndicatorLights(veh) or 0
    if ind & 1 ~= 0 then fl = fl | FLAG.left end
    if ind & 2 ~= 0 then fl = fl | FLAG.right end
    if yes(GetIsVehicleEngineRunning(veh)) then fl = fl | FLAG.engine end
    if yes(IsVehicleInBurnout(veh)) then fl = fl | FLAG.burnout end
    fl = TakeTrack.withGear(fl, Vehicles.dialGear(veh))
    return TakeTrack.quantize({ t, c.x, c.y, c.z, qx, qy, qz, qw, v.x, v.y, v.z,
        GetVehicleSteeringAngle(veh) or 0, GetVehicleCurrentRpm(veh) or 0, fl, w[1], w[2], w[3], w[4] })
end

--- The car on its spot: still, mended, engine on, the player at the wheel.
local function putBack(veh, st)
    SetEntityCoordsNoOffset(veh, st.x, st.y, st.z, false, false, true)
    SetEntityHeading(veh, st.heading or 0.0)
    SetVehicleOnGroundProperly(veh)
    SetEntityVelocity(veh, 0.0, 0.0, 0.0)
    SetEntityAngularVelocity(veh, 0.0, 0.0, 0.0)
    SetVehicleFixed(veh)
    SetVehicleDeformationFixed(veh)
    SetVehicleEngineOn(veh, true, true, false)
    local me = PlayerPedId()
    if GetVehiclePedIsIn(me, false) ~= veh then SetPedIntoVehicle(me, veh, -1) end
end

local function current(run) return R ~= nil and R.run == run end

--- A car of this game's own, and its riders in their seats (not networked: for the recording or the watch).
--- `driver`: a rider may have the driver's seat (another car's, beside a recording); else it is the player's.
local function makeCopy(model, x, y, z, heading, riders, driver)
    local hash = GetHashKey(model)
    if not IsModelInCdimage(hash) or not LoadModel(hash) then return nil, 'that car will not load here' end
    local veh = CreateVehicle(hash, x, y, z, heading, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not veh or veh == 0 then return nil, 'the car could not be made' end
    SetEntityAsMissionEntity(veh, true, true)
    SetVehRadioStation(veh, 'OFF')
    local peds = {}
    for _, r in ipairs(type(riders) == 'table' and riders or {}) do
        local seat = math.tointeger(tonumber(r.seat))
        local ph = type(r.model) == 'string' and GetHashKey(r.model) or 0
        if seat and (seat ~= -1 or driver) and ph ~= 0 and IsModelInCdimage(ph) and LoadModel(ph) then
            local ped = CreatePedInsideVehicle(veh, 4, ph, seat, false, false)
            SetModelAsNoLongerNeeded(ph)
            if ped and ped ~= 0 then
                SetEntityAsMissionEntity(ped, true, true)
                SetBlockingOfNonTemporaryEvents(ped, true)
                SetPedCanBeKnockedOffVehicle(ped, 1)
                peds[#peds + 1] = ped
            end
        end
    end
    return veh, peds
end

--- A copy just made, dressed as a run makes its car by the resources that keep something on the placed thing (its
--- `ext`: whip_autos puts on the Whiplash look), through the world builder's own event (client/furnish_builder.lua).
--- `driven`: the player drives this one (the recording's car), so its engine, handling and drivetrain count too.
local function dress(veh, wid, model, ext, driven)
    if not veh or type(wid) ~= 'string' or type(model) ~= 'string' or type(ext) ~= 'table' or not next(ext) then return end
    TriggerEvent('whip_core:director:builderCopy', { id = wid, kind = 'vehicle', model = model, entity = veh, data = ext,
                                                     driven = driven == true })
end

local function deleteCopy(veh, peds)
    for _, p in ipairs(peds or {}) do
        if DoesEntityExist(p) then SetEntityAsMissionEntity(p, true, true); DeleteEntity(p) end
    end
    if veh and DoesEntityExist(veh) then SetEntityAsMissionEntity(veh, true, true); DeleteEntity(veh) end
end

local function deleteOthers(others)
    for _, o in ipairs(others or {}) do
        deleteCopy(o.veh, o.peds)
        for _, tr in ipairs(o.trailers or {}) do deleteCopy(tr.veh, nil) end
    end
end

--- An other car's trailers, as its take had them (the page's `tow`: { tracks = { { w, id, model } }, events }): each one's
--- own track (`have`'s, fetched with the cars; else fetched now) and its copy made where that starts, and the car's
--- hitch moments by copy. Waits: a thread.
local function makeOtherTrailers(o, have)
    local tow = type(o.tow) == 'table' and o.tow or nil
    if not tow then return end
    local byW = {}
    o.trailers = {}
    for _, tr in ipairs(type(tow.tracks) == 'table' and tow.tracks or {}) do
        local tid = type(tr) == 'table' and math.tointeger(tonumber(tr.id)) or nil
        local ts = tid and type(tr.model) == 'string' and type(tr.w) == 'string' and (have[tid] or TakePlayer.fetch(tid)) or nil
        if ts then
            local x, y, z, h = TakePlayer.start(ts)
            local veh = makeCopy(tr.model, x, y, z, h, nil)
            if veh then
                dress(veh, tr.w, tr.model, tr.ext)
                o.trailers[#o.trailers + 1] = { veh = veh, samples = ts, at = { x = x, y = y, z = z, heading = h } }
                byW[tr.w] = veh
            end
        end
    end
    o.towEvents = {}
    for _, e in ipairs(type(tow.events) == 'table' and tow.events or {}) do
        if type(e) == 'table' and byW[e.w] then o.towEvents[#o.towEvents + 1] = { t = tonumber(e.t) or 0, on = e.on == true, veh = byW[e.w] } end
    end
end

--- The other cars beside a recording: each one's take fetched (all asked for at once), then its copy made where the
--- take starts, and its trailers on their own tracks (makeOtherTrailers). A take that cannot be fetched, or a car that
--- will not load, is left out and said. Waits: a thread.
---@param list table  { { car, label, model, take, riders, tow } } from the page
local function makeOthers(list)
    local want = {}
    for _, o in ipairs(type(list) == 'table' and list or {}) do
        local id = type(o) == 'table' and math.tointeger(tonumber(o.take)) or nil
        if id and type(o.model) == 'string' and #want < OTHERS_MAX then
            want[#want + 1] = { car = o.car, model = o.model, take = id, riders = o.riders, tow = o.tow, ext = o.ext,
                                label = type(o.label) == 'string' and DirectorKit.cut(o.label, 60) or o.model }
        end
    end
    if #want == 0 then return {} end
    -- (Their trailers' own tracks asked for in the same line and kept here, `have`: the game keeps only a few takes, and
    -- one dropped since would be asked for again, one by one.)
    local fetches, have = {}, {}
    for _, o in ipairs(want) do
        fetches[#fetches + 1] = { id = o.take, car = o }
        for _, tr in ipairs(type(o.tow) == 'table' and type(o.tow.tracks) == 'table' and o.tow.tracks or {}) do
            local tid = type(tr) == 'table' and math.tointeger(tonumber(tr.id)) or nil
            if tid then fetches[#fetches + 1] = { id = tid } end
        end
    end
    local left = #fetches
    for _, f in ipairs(fetches) do
        CreateThread(function()
            -- (All asked in one ask, the server sending them off this game's line: TakePlayer.fetch.)
            local samples = TakePlayer.fetch(f.id)
            if f.car then f.car.samples = samples else have[f.id] = samples end
            left = left - 1
        end)
    end
    ---@type integer|nil
    local sayAt = GetGameTimer() + 500
    while left > 0 do
        if sayAt and GetGameTimer() >= sayAt then
            sayAt = nil
            UI.Notify('Getting the other cars\' driving events...', 'info')
        end
        Wait(50)
    end
    local out, missed = {}, {}
    for _, o in ipairs(want) do
        local veh, peds
        if o.samples then
            local x, y, z, h = TakePlayer.start(o.samples)
            veh, peds = makeCopy(o.model, x, y, z, h, o.riders, true)
            if veh then
                ---@cast peds integer[]   -- (a car made: its riders)
                dress(veh, o.car, o.model, o.ext)
                for _, p in ipairs(peds) do SetEntityInvincible(p, true) end
                local other = { veh = veh, peds = peds, samples = o.samples, at = { x = x, y = y, z = z, heading = h },
                                label = o.label, tow = o.tow }
                makeOtherTrailers(other, have)
                out[#out + 1] = other
            end
        end
        if not veh then missed[#missed + 1] = o.label end
    end
    if #missed > 0 then
        UI.Notify(('Left out (its driving event could not be fetched, or it will not load): %s'):format(table.concat(missed, ', ')), 'warning', 7000)
    end
    return out
end

--- A copy back on a spot: still, mended, held.
local function holdAt(veh, at)
    if not DoesEntityExist(veh) then return end
    SetEntityCoordsNoOffset(veh, at.x, at.y, at.z, false, false, true)
    SetEntityHeading(veh, at.heading or 0.0)
    SetEntityVelocity(veh, 0.0, 0.0, 0.0)
    SetEntityAngularVelocity(veh, 0.0, 0.0, 0.0)
    SetVehicleFixed(veh)
    SetVehicleDeformationFixed(veh)
    FreezeEntityPosition(veh, true)
end

--- The other cars back where their takes start, still, mended, held until the GO; their trailers off the hitch and back
--- where their own tracks start (the take hitches them again when it did).
local function holdOthers(others)
    for _, o in ipairs(others) do
        if DoesEntityExist(o.veh) then
            TakePlayer.hitch(o.veh, nil)
            holdAt(o.veh, o.at)
            SetVehicleEngineOn(o.veh, true, true, false)
        end
        for _, tr in ipairs(o.trailers or {}) do holdAt(tr.veh, tr.at) end
    end
end

--- The GO: each other car drives its take from now, for as long as this attempt is the one going, and each of its
--- trailers its own track from the same moment, hitched and let go when they were.
local function driveOthers(others, still)
    local startAt = GetGameTimer()
    for _, o in ipairs(others) do
        local veh, samples = o.veh, o.samples
        if DoesEntityExist(veh) then
            FreezeEntityPosition(veh, false)
            CreateThread(function() TakePlayer.drive(veh, samples, still, { startAt = startAt, tow = o.towEvents }) end)
        end
        for _, tr in ipairs(o.trailers or {}) do
            if DoesEntityExist(tr.veh) then
                FreezeEntityPosition(tr.veh, false)
                CreateThread(function() TakePlayer.drive(tr.veh, tr.samples, still, { startAt = startAt }) end)
            end
        end
    end
end

--- The parked ones beside a recording (the page's `parked`: the scenario's other placed cars with no take, a trailer
--- among them), each a copy where it is placed. One that will not load is left out and said.
---@param list table  { { car, model, label, coords } }
local function makeParked(list)
    local out, missed = {}, {}
    for _, p in ipairs(type(list) == 'table' and list or {}) do
        local c = type(p) == 'table' and type(p.coords) == 'table' and p.coords or nil
        local x, y, z = c and tonumber(c.x), c and tonumber(c.y), c and tonumber(c.z)
        if #out < PARKED_MAX and type(p.car) == 'string' and type(p.model) == 'string' and x and y and z then
            ---@cast c table   -- (x, y and z were read off it)
            local veh = makeCopy(p.model, x, y, z, tonumber(c.heading) or 0.0, nil)
            if veh then
                dress(veh, p.car, p.model, p.ext)
                out[#out + 1] = { veh = veh, wid = p.car, model = p.model:lower(),
                                  at = { x = x, y = y, z = z, heading = tonumber(c.heading) or 0.0 } }
            else
                missed[#missed + 1] = type(p.label) == 'string' and DirectorKit.cut(p.label, 60) or p.model
            end
        end
    end
    if #missed > 0 then UI.Notify(('Left out (it will not load here): %s'):format(table.concat(missed, ', ')), 'warning', 7000) end
    return out
end

--- The parked ones back where they are placed, still and mended: held through the count, all but the car's own trailer
--- (hitched to it before the count, it hangs from the hitch).
local function holdParked(parked, tow)
    for _, p in ipairs(parked or {}) do
        local veh, at = p.veh, p.at
        if DoesEntityExist(veh) then
            FreezeEntityPosition(veh, false)
            SetEntityCoordsNoOffset(veh, at.x, at.y, at.z, false, false, true)
            SetEntityHeading(veh, at.heading or 0.0)
            SetVehicleOnGroundProperly(veh)
            SetEntityVelocity(veh, 0.0, 0.0, 0.0)
            SetEntityAngularVelocity(veh, 0.0, 0.0, 0.0)
            SetVehicleFixed(veh)
            SetVehicleDeformationFixed(veh)
            if p.wid ~= tow then FreezeEntityPosition(veh, true) end
        end
    end
end

local function freeParked(parked)
    for _, p in ipairs(parked or {}) do
        if DoesEntityExist(p.veh) then FreezeEntityPosition(p.veh, false) end
    end
end

local function deleteParked(parked)
    for _, p in ipairs(parked or {}) do deleteCopy(p.veh, nil) end
end

--- Which parked one this entity is (its placed thing's id), or nil.
local function parkedWid(parked, ent)
    if not ent then return nil end
    for _, p in ipairs(parked or {}) do
        if p.veh == ent then return p.wid end
    end
    return nil
end

--- The player back where they stood, and the editor back (`reopen`: the car recorded from the world builder, which
--- opens again on it).
local function goBack(back, reopen)
    local me = PlayerPedId()
    if back then
        SetEntityCoordsNoOffset(me, back.x, back.y, back.z, false, false, false)
        SetEntityHeading(me, back.h or 0.0)
    end
    PedHold.release('directorTake')
    DirectorScreen.back(reopen)
end

--- Every save of a drive (the car's and its trailers'), let go of (letGoOfSave).
local function letGoOfAll(rec)
    letGoOfSave(rec.buf)
    for _, p in ipairs(rec.parked or {}) do letGoOfSave(p.buf) end
end

local function finish(text, kind)
    if not R then return end
    local rec = R
    R = nil
    runs = runs + 1
    letGoOfAll(rec)
    deleteCopy(rec.veh, rec.peds)
    deleteOthers(rec.others)
    deleteParked(rec.parked)
    hud(true)
    goBack(rec.back, rec.reopen)
    if text then UI.Notify(text, kind or 'info') end
end

local function hold(why)
    R.phase, R.why = 'held', why
    hud(true)
end

--- The car's own trailer (its page's Tows) on its hitch, and the hitches kept from the start: one with it on is
--- hitched at 0. Each parked one's frames from the start too.
local function startTow()
    ---@cast R -nil   -- (an attempt is starting)
    local veh = R.veh
    TakePlayer.hitch(veh, nil)
    for _, p in ipairs(R.parked) do
        p.buf = TakeTrack.recorder()
        if p.wid == R.tow then TakePlayer.hitch(veh, p.veh) end
    end
    R.hitched, R.towEvents = nil, {}
end

--- The hitch as it is now (frame `t`): a parked one hitched or let go since the last frame is kept as a moment.
local function noteTow(t)
    ---@cast R -nil   -- (recording)
    local now = parkedWid(R.parked, TakePlayer.trailerOf(R.veh))
    if now == R.hitched then return end
    if R.hitched then R.towEvents[#R.towEvents + 1] = { t = t, w = R.hitched, on = false } end
    if now then R.towEvents[#R.towEvents + 1] = { t = t, w = now, on = true } end
    R.hitched = now
end

--- One attempt: back on the spot, count, record until saved, tried again or thrown away.
local function attempt()
    ---@cast R -nil   -- (newAttempt: a recording is up; current(run) says it still is)
    local run = R.run
    local veh = R.veh
    letGoOfAll(R)   -- (driven again while the last one's save was unanswered)
    R.phase, R.buf, R.t, R.why, R.saves = 'count', TakeTrack.recorder(), 0, nil, nil
    TakePlayer.hitch(veh, nil)
    putBack(veh, R.start)
    FreezeEntityPosition(veh, true)
    holdOthers(R.others)
    holdParked(R.parked, R.tow)
    startTow()
    local endsAt = GetGameTimer() + COUNT_MS
    local shown
    while current(run) do
        local left = endsAt - GetGameTimer()
        if left <= 0 then break end
        local n = math.ceil(left / 1000)
        if n ~= shown then
            shown, R.count = n, n
            PlaySoundFrontend(-1, '3_2_1', 'HUD_MINI_GAME_SOUNDSET', true)
            hud(true)
        end
        Wait(0)
    end
    if not current(run) then return end
    R.count = nil
    FreezeEntityPosition(veh, false)
    freeParked(R.parked)
    driveOthers(R.others, function() return current(run) end)
    PlaySoundFrontend(-1, 'GO', 'HUD_MINI_GAME_SOUNDSET', true)
    R.phase, R.t0 = 'rec', GetGameTimer()
    hud(true)
    -- Frame by frame while it records. Held or saving, nothing here is left to do (a key saves, tries again or throws
    -- it away: F11 starts a new attempt of its own), so the loop ends rather than wake every frame for nothing.
    while current(run) and R.phase == 'rec' do
        if not DoesEntityExist(veh) then
            hold('the car is gone')
        else
            local t = GetGameTimer() - R.t0
            TakeTrack.push(R.buf, sample(veh, t, R.buf))
            -- (Each parked one's frame too: a trailer hitched is saved as it went. One standing still is two.)
            for _, p in ipairs(R.parked) do
                if DoesEntityExist(p.veh) then TakeTrack.push(p.buf, sample(p.veh, t, p.buf)) end
            end
            noteTow(t)
            R.t = t
            if t >= MAX_S * 1000 then hold('the time limit') end
        end
        hud(false)
        Wait(0)
    end
end

local function newAttempt()
    runs = runs + 1
    R.run = runs
    CreateThread(attempt)
end

--- SAVING A LONG TAKE. It goes packed (TakeTrack.pack: about a quarter of its size), and how long the server is
--- given grows with that size (a three-minute drive is half a megabyte or so, and a player far from the server
--- sends a few tens of KB a second). Each drive has a token: the server keeps one take per token, so a Save pressed
--- again after a wait that ran out never makes a second copy, and its answer still counts when it comes late.
--- Every take a Save sends: the car's, then each parked one's that was hitched (its own placed thing's take).
--- { { wid (nil: the car's), buf, model } }, each buf finished; nil and why when there is nothing to save.
---@return table[]|nil list
---@return string|nil why
local function toSave()
    ---@cast R -nil   -- (save: a recording is up)
    local keys, n = TakeTrack.finish(R.buf)
    if n < 2 or (R.t or 0) < 500 then return nil, 'Nothing to save yet: drive a little first' end
    local list = { { buf = R.buf, keys = keys, model = R.model } }
    local hitched = {}
    for _, e in ipairs(R.towEvents or {}) do if e.on then hitched[e.w] = true end end
    for _, p in ipairs(R.parked) do
        if hitched[p.wid] and p.buf then
            local pk, pn = TakeTrack.finish(p.buf)
            if pn >= 2 then list[#list + 1] = { wid = p.wid, buf = p.buf, keys = pk, model = p.model } end
        end
    end
    return list
end

local function save()
    if not R or (R.phase ~= 'rec' and R.phase ~= 'held') then return end
    -- (Saved again after a wait that ran out: the same takes, each by its own token, never twice.)
    local list = R.saves and R.saves.list
    if not list then
        local why
        list, why = toSave()
        if not list then UI.Notify(why --[[@as string]], 'warning') return end
    end
    R.saves = { list = list, byToken = {} }
    local bytes = 0
    for _, s in ipairs(list) do
        local buf = s.buf
        buf.token = buf.token or ('%08x%08x'):format(math.random(0, 0x7fffffff), GetGameTimer() % 0x7fffffff)
        R.saves.byToken[buf.token] = s
        if not s.id then
            local packed = TakeTrack.pack(s.keys)
            local b = (msgpack and msgpack.pack) and #msgpack.pack(packed) or #packed.d * 3
            bytes = bytes + b
            buf.sent = true
            TriggerLatentServerEvent('whip_core:server:takeSave', SAVE_BPS, buf.token, R.key, s.wid or R.wid, s.model, packed)
        end
    end
    R.phase, R.why = 'saving', ('%d KB'):format(math.max(1, bytes // 1024))
    asks = asks + 1
    R.ask = asks
    R.keys = list[1].keys
    local ask = asks
    hud(true)
    SetTimeout(SAVE_WAIT_MS + bytes // SLOW_BYTES_PER_MS, function()
        if R and R.phase == 'saving' and R.ask == ask then
            hold('not saved yet')
            UI.Notify('The server has not answered yet: it may still be arriving. Wait a little, or Save again (it is never saved twice)', 'error')
        end
    end)
end

local function retry()
    if not R or R.phase == 'saving' then return end
    if not DoesEntityExist(R.veh) then UI.Notify('The car is gone: Discard, then record again', 'warning') return end
    newAttempt()
end

local function discard()
    if not R then return end
    if R.phase == 'saving' then UI.Notify('Saving: wait for the server to answer', 'warning') return end
    finish('Driving event thrown away')
end

local function makeKeys()
    if keysMade then return end
    keysMade = true
    RegisterCommand('director_take_save', save, false)
    RegisterCommand('director_take_retry', retry, false)
    RegisterCommand('director_take_discard', discard, false)
    RegisterKeyMapping('director_take_save', 'Director: save the driving event', 'keyboard', 'F10')
    RegisterKeyMapping('director_take_retry', 'Director: record the driving event again', 'keyboard', 'F11')
    RegisterKeyMapping('director_take_discard', 'Director: throw the driving event away', 'keyboard', 'F4')
end

RegisterNetEvent('whip_core:client:takeSaved', function(token, id, ms, why)
    local mine = R and R.saves and R.saves.byToken[token] or nil
    -- A drive let go before its answer came: the take the server wrote for it goes (nothing names it)
    if unanswered[token] and not mine then
        unanswered[token] = nil
        if id then TriggerServerEvent('whip_core:server:takeForget', token) end
        return
    end
    -- (This drive's answer, whichever Save it answers: held after a wait that ran out counts too.)
    if not mine or not R or (R.phase ~= 'saving' and R.phase ~= 'held') then return end
    if not id then
        hold('not saved')
        UI.Notify(why or 'The driving event was not saved', 'error')
        return
    end
    mine.buf.answered, mine.id, mine.ms = true, id, ms
    -- Every one of its takes answered (the car's and its trailers'): the car's take, with its trailers' as tow.
    for _, s in ipairs(R.saves.list) do if not s.id then return end end
    local car = R.saves.list[1]
    local tracks, n = {}, 0
    for i, s in ipairs(R.saves.list) do
        TakePlayer.keep(s.id, s.keys)
        if i > 1 then tracks[s.wid], n = s.id, n + 1 end
    end
    local tow = nil
    if n > 0 then
        local events = {}
        for _, e in ipairs(R.towEvents or {}) do
            if tracks[e.w] then events[#events + 1] = { t = e.t, w = e.w, on = e.on } end
        end
        tow = { tracks = tracks, events = events }
    end
    -- (Before the editor is back: a world builder opened again shows the car with this take on it.)
    SendNUIMessage({ action = 'directorTakeSaved', car = R.wid, id = car.id, ms = car.ms, tow = tow })
    finish(('Driving event saved (%d:%04.1f)%s'):format(math.floor(car.ms / 60000), (car.ms % 60000) / 1000,
        n > 0 and (', its trailer\'s movement with it') or ''), 'success')
end)

--- From the car's page: record a take in it. { key, car = worldId, model, label, coords, riders = { { model, seat } },
--- others, parked = { { car, model, label, coords } }, tow = its trailer's world id, builder }: `builder`, pressed in the
--- world builder, which opens again on the car once the take is over.
RegisterNUICallback('directorTakeRecord', function(d, cb)
    cb('ok')
    if type(d) ~= 'table' then return end
    local reopen = d.builder == true and type(d.car) == 'string' and d.car or nil
    -- (From the world builder the page stays out of the way while this starts: one that cannot start goes back to it.)
    local function refused()
        if reopen then DirectorScreen.reopen(reopen) end
    end
    if R or watching or starting or type(d.model) ~= 'string' or type(d.coords) ~= 'table' then return refused() end
    if type(d.key) ~= 'string' or type(d.car) ~= 'string' or PlayerIsDead then return refused() end
    local c = d.coords
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not (x and y and z) then return refused() end
    if not DirectorScreen.aside() then return refused() end
    CreateThread(function()
        local gen = setupGen
        local me = PlayerPedId()
        local here = GetEntityCoords(me)
        local back = { x = here.x, y = here.y, z = here.z, h = GetEntityHeading(me) }
        local veh, peds = makeCopy(d.model, x, y, z, tonumber(c.heading) or 0.0, d.riders)
        -- A death or a logout while it was being set up (abandon): nothing starts, and nobody is moved
        local function called() return gen ~= setupGen or PlayerIsDead or not PlayerLoaded end
        if veh and called() then deleteCopy(veh, peds) return end
        if not veh then
            UI.Notify(tostring(peds), 'error')
            goBack(nil, reopen)
            return
        end
        ---@cast peds integer[]   -- (a car made: its riders)
        dress(veh, d.car, d.model, d.ext, true)
        -- (Held here while their takes come: one this game has not got yet is a few seconds on a slow connection.)
        FreezeEntityPosition(veh, true)
        starting = true
        local others = makeOthers(d.others)
        local parked = makeParked(d.parked)
        if called() then
            deleteCopy(veh, peds)
            deleteOthers(others)
            deleteParked(parked)
            if gen == setupGen then starting = false end
            return
        end
        starting = false
        makeKeys()
        -- (Its own trailer, when it is among the parked ones: the page sends it there.)
        local tow = nil
        for _, p in ipairs(parked) do if p.wid == d.tow then tow = p.wid end end
        R = { key = d.key, wid = d.car, model = d.model:lower(), label = type(d.label) == 'string' and DirectorKit.cut(d.label, 60) or d.model,
              start = { x = x, y = y, z = z, heading = tonumber(c.heading) or 0.0 }, veh = veh, peds = peds, others = others,
              parked = parked, tow = tow, back = back, reopen = reopen }
        local names = {}
        for i, o in ipairs(others) do names[i] = o.label end
        local with = #names == 0 and '' or ('. Their driving events play with you: %s'):format(table.concat(names, ', '))
        if tow then with = with .. '. Its trailer is on: drive with it' end
        UI.Notify('Drive when the count ends: F10 saves, F11 starts again, F4 throws it away' .. with, 'info', 7000)
        newAttempt()
    end)
end)

--- From the car's page: watch a take, riding along. { id, model, tow = { tracks = { { w, id, model } }, events } }.
RegisterNUICallback('directorTakeWatch', function(d, cb)
    cb('ok')
    local id = type(d) == 'table' and math.tointeger(tonumber(d.id)) or nil
    if R or watching or not id or type(d.model) ~= 'string' or PlayerIsDead then return end
    if not DirectorScreen.aside() then return end
    watching = true
    watchRun = watchRun + 1
    local mine = watchRun
    CreateThread(function()
        local samples = TakePlayer.fetch(id)
        -- Ended while it was fetched (a death or a logout: abandon): nothing is held, nobody is seated or moved
        local function ended() return watchRun ~= mine or PlayerIsDead or not PlayerLoaded end
        if ended() then
            if watchRun == mine then watching = false end
            return
        end
        local me = PlayerPedId()
        local here = GetEntityCoords(me)
        local back = { x = here.x, y = here.y, z = here.z, h = GetEntityHeading(me) }
        if not samples then
            UI.Notify('That driving event could not be fetched', 'error')
            watching = false
            goBack(nil)
            return
        end
        local x, y, z, h = TakePlayer.start(samples)
        local veh, peds = makeCopy(d.model, x, y, z, h, nil)
        -- Its trailers (the take's tow: { tracks = { { w, id, model } }, events }): each a copy where its own track starts,
        -- driven along it beside the car, hitched and let go when they were.
        local trailers, byW = {}, {}
        local tow = type(d.tow) == 'table' and d.tow or {}
        for _, tr in ipairs(veh and type(tow.tracks) == 'table' and tow.tracks or {}) do
            local tid = type(tr) == 'table' and math.tointeger(tonumber(tr.id)) or nil
            local ts = tid and type(tr.model) == 'string' and type(tr.w) == 'string' and TakePlayer.fetch(tid) or nil
            if ts then
                local tx, ty, tz, th = TakePlayer.start(ts)
                local tv = makeCopy(tr.model, tx, ty, tz, th, nil)
                if tv then
                    dress(tv, tr.w, tr.model, tr.ext)
                    trailers[#trailers + 1] = { veh = tv, samples = ts }
                    byW[tr.w] = tv
                end
            end
        end
        local function dropTrailers() for _, tr in ipairs(trailers) do deleteCopy(tr.veh, nil) end end
        if veh and ended() then
            deleteCopy(veh, peds)
            dropTrailers()
            if watchRun == mine then watching = false end
            return
        end
        if not veh then
            UI.Notify(tostring(peds), 'error')
            watching = false
            goBack(nil)
            return
        end
        dress(veh, d.car, d.model, d.ext)
        PedHold.set('directorTake', { invincible = true })
        SetPedIntoVehicle(me, veh, 0)
        local still = function() return watching and watchRun == mine and not PlayerIsDead end
        local events = {}
        for _, e in ipairs(type(tow.events) == 'table' and tow.events or {}) do
            if type(e) == 'table' and byW[e.w] then events[#events + 1] = { t = tonumber(e.t) or 0, on = e.on == true, veh = byW[e.w] } end
        end
        local startAt = GetGameTimer() + 100
        for _, tr in ipairs(trailers) do
            CreateThread(function() TakePlayer.drive(tr.veh, tr.samples, still, { startAt = startAt }) end)
        end
        TakePlayer.drive(veh, samples, still, { startAt = startAt, tow = events })
        -- Ended by a death or a logout (abandon, below): the copy goes, and nobody is moved back
        if watchRun ~= mine then deleteCopy(veh, peds) dropTrailers() return end
        Wait(1500)
        deleteCopy(veh, peds)
        dropTrailers()
        if watchRun ~= mine then return end
        watching = false
        goBack(back)
    end)
end)

-- ---- riding along (the Play Scripted Driving Event card's Ride along: server/director/nodes_tasks.lua) ----
--
-- The server names this player. Far from the car they are moved beside it behind a fade (a car only comes to a game near
-- it), then put at its wheel, unhurt, with only the camera, chat and the pause menu working, as whip_scenes' ride. Their
-- game says "seated" and the take starts. It ends when the server says (out of the car, if the card's ending wants
-- that), and by itself when the car goes, they are out of it, or the time it was given is up: nothing the server fails
-- to say can leave a player held.

local RIDE_CONTROLS  = { 0, 1, 2, 3, 4, 5, 6, 26, 79, 80, 199, 200, 245, 249 }
local RIDE_FAR       = 30.0    -- metres from the car: further, moved to it behind a fade
local RIDE_FADE_MS   = 250
local RIDE_FADED_MS  = 1000    -- the fade is waited for this long at most
local RIDE_SEAT_MS   = 6000    -- the car is waited for this long at most
local RIDE_LOOK_MS   = 250

local ride = nil   -- { token, untilAt, veh, faded }

local function rideOver()
    local r = ride
    if not r then return end
    ride = nil
    ControlBlocks.release('directorRide')
    PedHold.release('directorRide')
    if r.faded then DoScreenFadeIn(RIDE_FADE_MS) end
end

local function rideCar(netId) return DirectorKit.entityOfNet(netId, 2) end

--- `at`: where the car is. `maxMs`: from now, when this lets go by itself.
RegisterNetEvent('whip_core:client:takeRide', function(token, netId, at, maxMs)
    if type(token) ~= 'number' or type(netId) ~= 'number' or type(at) ~= 'table' then return end
    rideOver()
    if PlayerIsDead or not PlayerLoaded then
        TriggerServerEvent('whip_core:server:takeRideSeated', token, false)
        return
    end
    local r = { token = token, untilAt = GetGameTimer() + (tonumber(maxMs) or 0) }
    ride = r
    ControlBlocks.hold('directorRide', { all = true, except = RIDE_CONTROLS })
    PedHold.set('directorRide', { invincible = true })
    CreateThread(function()
        local me = PlayerPedId()
        local here = GetEntityCoords(me)
        local dx, dy, dz = here.x - at.x, here.y - at.y, here.z - at.z
        if dx * dx + dy * dy + dz * dz > RIDE_FAR * RIDE_FAR then
            r.faded = true
            DoScreenFadeOut(RIDE_FADE_MS)
            local fadeUntil = GetGameTimer() + RIDE_FADED_MS
            while ride == r and not IsScreenFadedOut() and GetGameTimer() < fadeUntil do Wait(0) end
            if ride ~= r then return end
            RequestCollisionAtCoord(at.x, at.y, at.z)
            SetEntityCoordsNoOffset(me, at.x, at.y, at.z + 1.0, false, false, false)
            PedHold.set('directorRide', { invincible = true, frozen = true })   -- (the ground may not be here yet)
        end
        local veh, seated = nil, false
        local giveUp = GetGameTimer() + RIDE_SEAT_MS
        while ride == r and not seated and GetGameTimer() < giveUp do
            veh = rideCar(netId)
            if veh then
                PedHold.set('directorRide', { invincible = true })
                SetPedIntoVehicle(me, veh, -1)
                seated = GetPedInVehicleSeat(veh, -1) == me
            end
            if not seated then Wait(100) end
        end
        if ride ~= r then return end
        if not seated then
            rideOver()
            TriggerServerEvent('whip_core:server:takeRideSeated', token, false)
            return
        end
        ---@cast veh -nil   -- (seated: in it)
        r.veh = veh
        -- (Theirs before the take starts: its first frames play here, not on whoever had the car.)
        Vehicles.takeControl(veh, { attempts = 3, wait = 300 })
        if ride ~= r then return end
        if r.faded then
            r.faded = false
            DoScreenFadeIn(RIDE_FADE_MS)
        end
        TriggerServerEvent('whip_core:server:takeRideSeated', token, true)
        while ride == r do
            Wait(RIDE_LOOK_MS)
            if ride == r and (not DoesEntityExist(veh) or GetVehiclePedIsIn(PlayerPedId(), false) ~= veh
                or GetGameTimer() >= r.untilAt) then
                rideOver()
            end
        end
    end)
end)

RegisterNetEvent('whip_core:client:takeRideOver', function(token, getOut)
    if not ride or ride.token ~= token then return end
    local veh = ride.veh
    rideOver()
    if getOut == true and veh and DoesEntityExist(veh) and GetVehiclePedIsIn(PlayerPedId(), false) == veh then
        TaskLeaveVehicle(PlayerPedId(), veh, 0)
    end
end)

--- Death or logout: a recording or a watch ends where it is. Nothing is saved and nobody is moved (the death or the
--- logout moved them already); the copy cars go, and the keys do nothing until the next one.
local function abandon()
    rideOver()
    -- A recording still being set up (its other cars' takes on their way) is called off too
    setupGen, starting = setupGen + 1, false
    if R then
        local rec = R
        R = nil
        runs = runs + 1
        letGoOfAll(rec)
        deleteCopy(rec.veh, rec.peds)
        deleteOthers(rec.others)
        deleteParked(rec.parked)
        hud(true)
    end
    if watching then
        watching = false
        watchRun = watchRun + 1
    end
    PedHold.release('directorTake')
end
AddEventHandler('whip_core:player:died', abandon)
AddEventHandler('whip_core:player:logout', abandon)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if R then deleteCopy(R.veh, R.peds); deleteOthers(R.others); deleteParked(R.parked) end
    PedHold.release('directorTake')
    rideOver()
end)
