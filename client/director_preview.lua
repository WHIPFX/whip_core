-- ============================================
-- Director — previewing tasks and takes in the world builder (client)
-- ============================================
--
-- PLAY HERE (a thing's Tasks tab, while the world builder is open): its tasks, played on the builder's own copy
-- of it where it stands, and on the things it plays with (its tasks' "Play with"), from the same moment, while you
-- watch from the free camera. Only on this screen: nothing is made, sent or networked, and no run is started. A
-- car's take (its Takes tab's Play here) drives the copy along the recording, its riders in their seats, and its
-- line is drawn where it goes.
--
-- The page has the server read each list (the 'previewPlans' request: server/director/tasks.lua, as a run reads it)
-- and hands this file the steps (directorPreviewPlay). Each step is played as a run plays it, by the same code:
-- an NPC's by client/npcs.lua (NpcSteps), a car's by client/actors.lua (ActorSteps; a take by TakePlayer), a prop's
-- timeline by client/prop_sets.lua (PropSets.applyMotion). Who a step points at is worked out here: the nearest
-- player is you, a placed thing is its copy here, a car to get in is the car's copy. A take's trailers (each hitched
-- trailer's own track, the page's `tow` on the step: its Takes tab or a task's take alike) are played on their copies
-- from the moment the car's take starts, and the car's hitch takes them on and lets them go when it did.
--
-- A fight is not played (said in the page, and passed over), nor a Wait for a card (no run). The nearest player is
-- your camera for a look, an aim, a shot, a throw, a turn or running away. A car's Blow Up is only seen.
--
-- STOP puts every copy back where it is placed, as the builder holds it (frozen, see-through, passing through
-- things); so does a new Play, and closing the builder. A preview that has played to its end does it by itself, a
-- moment after (END_HOLD_MS: where they got to is seen first), so they can be picked again where they stand.
--
-- No Wait(0) but a take's (TakePlayer.drive) and a prop timeline's, and the take's line, only while the builder
-- shows it.

local HELD_ALPHA = 200           -- the builder's see-through copy (client/furnish_builder.lua)
local POLL_MS = 250
local END_HOLD_MS = 1000         -- played to its end: left where it got to this long, then put back
local MIN_LAP_MS = 1000          -- a list that starts again goes round no faster than this
-- (What it passes over, previewSkip, and what points at the free camera, previewAtCamera: "the nearest player" here
-- is you, and you are the camera, not your player standing somewhere else, hidden. shared/director/steps.lua.)
local is = DirectorSteps.is

local runs = {}       -- [worldId] = { id, kind, it, ent, gen, steps, after, along, was = { frozen, alpha, noCollide } }
                      -- (along: a trailer a take drives, no list of its own)
local gen = 0         -- a new Play or a Stop ends every run of the one before
local live = 0        -- runs still playing
local path = nil      -- { take, joints, pieces } a take's line (lineOf)
local drawing = false

local function say(st, extra)
    local ids = {}
    for id in pairs(runs) do ids[#ids + 1] = id end
    local msg = { action = 'directorPreviewState', state = st, ids = ids }
    for k, v in pairs(extra or {}) do msg[k] = v end
    SendNUIMessage(msg)
end

local function myId() return GetPlayerServerId(PlayerId()) end

--- Is the builder still open on the Director's session, and this preview the one playing?
local function still(r) return r.gen == gen and FurnishBuilder.open() end

--- Wait `ms`, a slice at a time; false once the preview was stopped.
local function sleep(r, ms)
    local untilAt = GetGameTimer() + ms
    while GetGameTimer() < untilAt do
        if not still(r) then return false end
        Wait(math.min(100, math.max(0, untilAt - GetGameTimer())))
    end
    return still(r)
end

-- ---- a copy freed to move, and put back ----

local function free(r)
    local ent = r.ent
    -- (How the builder holds it, to put it back so: frozen, see-through, passing through things.)
    local noCollide = true
    if GetEntityCollisionDisabled then
        local v = GetEntityCollisionDisabled(ent)
        noCollide = v == true or v == 1
    end
    r.was = { frozen = IsEntityPositionFrozen(ent), alpha = GetEntityAlpha(ent), noCollide = noCollide }
    -- (The builder points at it, and its bubble stands by it, where it has got to: client/property_furnish.lua.)
    r.it.playing = true
    FreezeEntityPosition(ent, false)
    SetEntityCollision(ent, true, true)
    ResetEntityAlpha(ent)
    if r.kind == 'npc' then ClearPedTasksImmediately(ent) end
    if r.kind == 'vehicle' then SetVehicleEngineOn(ent, true, true, false) end
end

local function putBack(r)
    local ent, it = r.ent, r.it
    it.playing = nil
    if not ent or not DoesEntityExist(ent) then return end
    if r.kind == 'npc' then
        if IsPedInAnyVehicle(ent, false) then TaskLeaveVehicle(ent, GetVehiclePedIsIn(ent, false), 16) end   -- 16: at once
        ClearPedTasksImmediately(ent)
        if IsPedDeadOrDying(ent, true) then ResurrectPed(ent) end
        SetEntityHealth(ent, GetEntityMaxHealth(ent))
        -- (Not hurt, no cover point of its own, nothing in its hands: what it was given or thrown is put away.)
        NpcSteps.reset(ent)
    elseif r.kind == 'vehicle' then
        SetVehicleFixed(ent)
        SetVehicleEngineHealth(ent, 1000.0)
        SetVehicleHandbrake(ent, false)
        SetVehicleSiren(ent, false)
        SetVehicleEngineOn(ent, false, true, false)
    end
    SetEntityVelocity(ent, 0.0, 0.0, 0.0)
    SetEntityCoordsNoOffset(ent, it.x, it.y, it.z, false, false, false)
    if r.kind == 'prop' then
        SetEntityRotation(ent, (it.rx or 0.0) + 0.0, (it.ry or 0.0) + 0.0, (it.rz or 0.0) + 0.0, 2, false)
    else
        SetEntityHeading(ent, (it.rz or 0.0) + 0.0)
    end
    local was = r.was or { frozen = true, alpha = HELD_ALPHA, noCollide = true }
    FreezeEntityPosition(ent, was.frozen ~= false)
    if was.noCollide then SetEntityCollision(ent, false, false) end
    if (was.alpha or 255) < 255 then SetEntityAlpha(ent, was.alpha, false) else ResetEntityAlpha(ent) end
end

-- ---- a step's targets, here ----

--- A step's params, its targets worked out here (as server/director/nodes_tasks.lua's resolver does for a run).
local function resolve(s)
    local p = {}
    for k, v in pairs(type(s.p) == 'table' and s.p or {}) do p[k] = v end
    local t = p.target
    if (t == 'nearest' or t == 'trigger') and is(s.t, 'previewAtCamera') then
        local c = GetFinalRenderedCamCoord()
        p.tAt = { x = c.x, y = c.y, z = c.z }
    elseif t == 'nearest' or t == 'trigger' then
        p.tSid = myId()
    elseif t == 'thing' then
        local o = FurnishBuilder.itemOf(p.thing)
        if o and o.obj and DoesEntityExist(o.obj) then p.tEnt = o.obj elseif o then p.tAt = { x = o.x, y = o.y, z = o.z } end
    elseif t == 'point' then
        p.tAt = p.at
    end
    if s.t == 'getIn' or s.t == 'warpIn' then
        local o = FurnishBuilder.itemOf(p.car)
        p.carEnt = o and o.obj or nil
    end
    -- Another resource's step: a field naming a placed thing (hub.lua previewPlans marks them) is its copy here.
    for k, v in pairs(p) do
        if type(v) == 'table' and v.thing ~= nil then
            local o = FurnishBuilder.itemOf(v.thing)
            p[k] = { thing = v.thing, ent = o and o.obj or nil }
        end
    end
    return p
end

-- ---- playing a list ----

--- The step after step i that it walks on into without stopping (a Go To after a Go To, as server/task_seq.lua sends
--- `ahead`), its params, else nil.
local function aheadOf(r, i)
    local s = r.steps[i]
    if s.timing ~= 'until' or not is(s.t, 'flows') then return nil end
    local nxt = r.steps[i + 1] or (r.after == 'loop' and r.steps[1]) or nil
    if not nxt or nxt.timing ~= 'until' or not is(nxt.t, 'flows') then return nil end
    return resolve(nxt)
end

local function playNpc(r, s, left, ahead)
    local ped = r.ent
    if s.t == 'freeze' then FreezeEntityPosition(ped, s.p and s.p.on ~= false) return nil end
    local w = { preview = true, ped = ped, still = function() return still(r) end }
    local ok, look = pcall(NpcSteps.run, ped, w, { t = s.t, p = resolve(s), ms = s.ms, timing = s.timing, ahead = ahead }, left)
    if not ok then print('[whip_core:preview] ' .. tostring(s.t) .. ': ' .. tostring(look)) return nil end
    return look
end

local function waitUntil(r, s, test)
    local untilAt = GetGameTimer() + (s.giveUpMs or 30000)
    while GetGameTimer() < untilAt do
        if not still(r) then return end
        local how = test()
        if how then return end
        Wait(POLL_MS)
    end
end

--- A take's trailers here (the page's `tow`: { tracks = { { w, id, model } }, events }): each one's copy, freed to drive
--- its own track and put back with the rest (it joins `runs`, `along`), and the car's hitch moments by copy. A trailer
--- playing a list of its own in this preview is left to it; one with no copy here is said. Waits: a thread (fetches).
---@return table trailers  { { ent, samples } }
---@return table|nil tow   { { t, on, veh } } for TakePlayer.drive
local function trailersFor(r, tow)
    if type(tow) ~= 'table' then return {}, nil end
    local list, byW, missing = {}, {}, {}
    for _, tr in ipairs(type(tow.tracks) == 'table' and tow.tracks or {}) do
        local w = type(tr) == 'table' and type(tr.w) == 'string' and tr.w or nil
        local own = w and runs[w] or nil
        local it = w and not (own and not own.along) and FurnishBuilder.itemOf(w) or nil
        local samples = it and it.obj and DoesEntityExist(it.obj) and TakePlayer.fetch(math.tointeger(tonumber(tr.id))) or nil
        -- (The fetch waits: Stopped meanwhile, nothing more is set going. The caller says nothing more either.)
        if not still(r) then return {}, nil end
        if samples then
            -- (Fetched only for a copy here, found by its id.)
            ---@cast it -nil
            ---@cast w -nil
            if not own then
                own = { id = w, kind = 'vehicle', label = w, it = it, ent = it.obj, gen = r.gen, steps = {}, after = 'stop', along = true }
                runs[w] = own
                free(own)
            end
            DetachVehicleFromTrailer(it.obj)
            list[#list + 1] = { ent = it.obj, samples = samples }
            byW[w] = it.obj
        elseif w and not own then
            missing[#missing + 1] = w
        end
    end
    if #missing > 0 then
        say('note', { note = ('%s: its trailer is not here (no copy, or its movement could not be fetched): %s'):format(r.label or r.id, table.concat(missing, ', ')) })
    end
    local hitches = nil
    for _, e in ipairs(type(tow.events) == 'table' and tow.events or {}) do
        if type(e) == 'table' and byW[e.w] then
            hitches = hitches or {}
            hitches[#hitches + 1] = { t = tonumber(e.t) or 0, on = e.on == true, veh = byW[e.w] }
        end
    end
    return list, hitches
end

local function playCar(r, s, left)
    local veh = r.ent
    if s.t == 'take' then
        local p = type(s.p) == 'table' and s.p or {}
        local samples = TakePlayer.fetch(p.take)
        if not samples or not still(r) then return end
        local trailers, tow = trailersFor(r, p.tow)
        if not still(r) then return end
        DetachVehicleFromTrailer(veh)   -- (a list going round: the take hitches it again when it did)
        local startAt = GetGameTimer()
        for _, tr in ipairs(trailers) do
            CreateThread(function() TakePlayer.drive(tr.ent, tr.samples, function() return still(r) end, { startAt = startAt }) end)
        end
        -- (What its list's Lights, Indicators, Siren and Engine set, the drive leaves to them, as in a run.)
        TakePlayer.drive(veh, samples, function() return still(r) end,
            { startAt = startAt, tow = tow, leave = DirectorSteps.leftByDrives(r.steps) })
    elseif s.t == 'brake' then
        SetVehicleHandbrake(veh, true)
        SetVehicleBrakeLights(veh, true)
        sleep(r, left)
        SetVehicleHandbrake(veh, false)
    elseif s.t == 'speedTo' then
        local untilAt = GetGameTimer() + left
        while GetGameTimer() < untilAt and still(r) do
            SetVehicleForwardSpeed(veh, (s.p and s.p.mps or 15.0) + 0.0)
            Wait(100)
        end
    elseif s.t == 'freeze' then
        FreezeEntityPosition(veh, s.p and s.p.on ~= false)
    elseif s.t == 'flashLights' then
        local untilAt, on = GetGameTimer() + left, false
        while GetGameTimer() < untilAt and still(r) do
            on = not on
            SetVehicleLights(veh, on and 2 or 1)
            Wait(250)
        end
        SetVehicleLights(veh, 0)
    elseif s.t == 'horn' then
        StartVehicleHorn(veh, math.floor(left), GetHashKey('HELDDOWN'), false)
    elseif s.t == 'blowUp' then
        -- (Seen, never felt: no damage, as the copy is right here.)
        local c = GetEntityCoords(veh)
        AddExplosion(c.x, c.y, c.z, 7, 0.0, true, false, 1.0)
        SetVehicleEngineHealth(veh, 0.0)
    elseif s.t == 'everyoneOut' then
        ActorSteps.run(veh, s, left)
        waitUntil(r, s, function() return ActorSteps.empty(veh) end)
    elseif DirectorTaskSteps.isSatellite(s.t) then
        -- Another resource's (Whip.task), by its own code, on this copy.
        local look = DirectorTaskSteps.run(veh, 'vehicle', { t = s.t, p = resolve(s), timing = s.timing }, left, true)
        if s.timing == 'until' then waitUntil(r, s, function() return DirectorTaskSteps.done(veh, look) end) end
    elseif s.t ~= 'wait' then
        ActorSteps.run(veh, { t = s.t, p = resolve(s) }, left)
    end
    if s.timing == 'timed' and s.t ~= 'brake' and s.t ~= 'speedTo' and s.t ~= 'flashLights' then sleep(r, left) end
end

--- A prop's list is a timeline (every step has its length): played from now, as every game plays a run's.
local function playProp(r)
    local it = r.it
    local p = { x = it.x, y = it.y, z = it.z, rx = it.rx or 0.0, ry = it.ry or 0.0, rz = it.rz or 0.0 }
    local m = { steps = r.steps, at = GetGameTimer(), loop = r.after == 'loop' }
    local total = 0
    for _, s in ipairs(r.steps) do total = total + (s.ms or 0) end
    while still(r) and DoesEntityExist(r.ent) do
        PropSets.applyMotion(r.ent, p, m, GetGameTimer())
        if not m.loop and GetGameTimer() - m.at >= total then break end
        Wait(0)
    end
end

local function playList(r)
    if r.kind == 'prop' then playProp(r) return end
    repeat
        -- (A round over at once, one Go To it is already at, would never let the game draw a frame: each step yields,
        -- and a round that starts again lasts MIN_LAP_MS at least, as server/task_seq.lua's do.)
        local lapAt = GetGameTimer()
        for i, s in ipairs(r.steps) do
            Wait(0)
            if not still(r) or not DoesEntityExist(r.ent) then return end
            local left = s.ms or s.giveUpMs or 10000
            if s.t == 'wait' and type(s.p) == 'table' and s.p.by == 'card' then
                -- (No run here: a card never gives its outcome. A moment's pause in its place.)
                say('note', { note = ('%s: Wait for a card is passed over here (it waits in a run)'):format(r.label or r.id) })
                sleep(r, 1000)
            elseif is(s.t, 'previewSkip') then
                local d = DirectorSteps.get(s.t)
                say('note', { note = ('%s: %s is not played here (%s): it plays in a run'):format(r.label or r.id, d.label, d.previewSkip) })
            elseif r.kind == 'npc' then
                local look = playNpc(r, s, left, aheadOf(r, i))
                if s.timing == 'timed' then sleep(r, left)
                elseif s.timing == 'until' then waitUntil(r, s, function() return NpcSteps.done(r.ent, look) end) end
            elseif r.kind == 'vehicle' then
                playCar(r, s, left)
            end
        end
        local lap = GetGameTimer() - lapAt
        if r.after == 'loop' and lap < MIN_LAP_MS then sleep(r, MIN_LAP_MS - lap) end
    until r.after ~= 'loop' or not still(r)
end

--- Every copy back where it is placed, and the preview over.
local function stop()
    gen = gen + 1
    -- (Off every hitch first, so each trailer is put back on its own.)
    for _, r in pairs(runs) do
        if r.kind == 'vehicle' and r.ent and DoesEntityExist(r.ent) then DetachVehicleFromTrailer(r.ent) end
    end
    for _, r in pairs(runs) do pcall(putBack, r) end
    runs, live = {}, 0
end

--- Play these lists from now: { { id, kind, label, plan = { steps, after } } }.
local function play(list)
    stop()
    if not FurnishBuilder.open() then return end
    local missing = {}
    for _, x in ipairs(type(list) == 'table' and list or {}) do
        local it = type(x) == 'table' and FurnishBuilder.itemOf(x.id) or nil
        local plan = type(x) == 'table' and x.plan or nil
        if it and it.obj and DoesEntityExist(it.obj) and type(plan) == 'table' and type(plan.steps) == 'table' and #plan.steps > 0 then
            runs[x.id] = { id = x.id, kind = x.kind, label = x.label, it = it, ent = it.obj, gen = gen,
                           steps = plan.steps, after = plan.after }
        elseif type(x) == 'table' then
            missing[#missing + 1] = tostring(x.label or x.id)
        end
    end
    if next(runs) == nil then
        say('idle', { note = #missing > 0 and ('Nothing to play: ' .. table.concat(missing, ', ') .. ' (no copy here, or no tasks)') or 'Nothing to play' })
        return
    end
    for _, r in pairs(runs) do
        free(r)
        live = live + 1
        CreateThread(function()
            local ok, err = pcall(playList, r)
            if not ok then print('[whip_core:preview] ' .. tostring(r.id) .. ': ' .. tostring(err)) end
            if r.gen ~= gen then return end
            live = live - 1
            if live > 0 then return end
            say('done')
            local played = gen
            SetTimeout(END_HOLD_MS, function()
                if played ~= gen then return end   -- (played again, or stopped, meanwhile)
                stop()
                say('idle')
            end)
        end)
    end
    say('playing', #missing > 0 and { note = 'Not here: ' .. table.concat(missing, ', ') } or nil)
end

-- ---- a take's line ----
--
-- White chevrons down the car's drive, pointing the way it went: one tile of it is a texture (html/interact3d/
-- takeline.html), laid tile after tile over the ground. Worked out once as the take is opened: the drive cut into
-- even lengths, each cut turned halfway between the pieces either side of it, so the tiles meet without a gap on a
-- bend; lowered from the car's middle to the ground by how high the car stood over it at the start (the same car the
-- whole drive, so a hill is followed and a jump is seen). Only the pieces near the camera are drawn, and only while
-- its car is selected (as a guard's cone).

local LINE_W      = 1.4       -- metres across
local LINE_L      = 2.8       -- one tile along (the texture is twice as tall as it is wide)
local LINE_LIFT   = 0.06      -- over the ground, so it is not lost in it
local LINE_NEAR_M = 160.0     -- pieces further from the camera than this are not drawn
local LINE_PIECE  = 16        -- tiles in a piece, kept or passed over together
local LINE_TXD, LINE_TEX = 'whip_take_line_txd', 'line'

local pathWant = nil          -- the take whose line was asked for last (a slower fetch of another one is dropped)

--- The line's browser: made when a line is shown, given back (DUI rules: released when idle) when there is no line
--- to draw or the builder closed, and made again the next time a line is shown.
local linePage = DuiPage.new({
    name = 'preview', url = 'interact3d/takeline.html?w=256&h=512&n=3', width = 256, height = 512,
    txd = LINE_TXD, tex = LINE_TEX, without = "a take's line will not draw",
})

local function lineAttach() linePage:ensure() end
local function lineRelease() linePage:release() end

--- The drive as joints a tile apart, from where it starts: { l, r = { x, y, z }, v } (`v`: how much of a tile the
--- piece that ends at it is), and the pieces to cull by: { from, to, x, y, z, r }. Nil for a drive with no length.
local function lineOf(samples)
    local K = TakeTrack.STRIDE
    local n = #samples // K
    if n < 2 then return nil end
    -- How high the car's middle stood over the ground at the start.
    local x0, y0, z0 = samples[2], samples[3], samples[4]
    local found, gz = GetGroundZFor_3dCoord(x0, y0, z0 + 1.0, false)
    local over = (found and z0 - gz >= 0.0 and z0 - gz <= 2.5) and (z0 - gz) or 0.5
    -- Its points, each a little way on from the last.
    local pts, lx, ly = {}, nil, nil
    for j = 0, n - 1 do
        local b = j * K
        local x, y, z = samples[b + 2], samples[b + 3], samples[b + 4]
        if not lx or (x - lx) ^ 2 + (y - ly) ^ 2 >= 0.0625 then
            pts[#pts + 1] = { x, y, z - over + LINE_LIFT }
            lx, ly = x, y
        end
    end
    if #pts < 2 then return nil end
    -- Cut every LINE_L along the way, and where it ends.
    local cuts, need = { pts[1] }, LINE_L
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local seg = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
        local used = 0.0
        while seg - used >= need do
            used = used + need
            local t = used / seg
            cuts[#cuts + 1] = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, 1.0 }
            need = LINE_L
        end
        need = need - (seg - used)
    end
    local tail = LINE_L - need
    if tail > 0.05 then
        local last = pts[#pts]
        cuts[#cuts + 1] = { last[1], last[2], last[3], tail / LINE_L }
    end
    if #cuts < 2 then return nil end
    -- Each joint across the way: turned halfway between the pieces either side, and wider at a bend by as much as
    -- the turn takes (up to twice), so the tiles either side meet along it.
    local joints, half = {}, LINE_W / 2
    for i = 1, #cuts do
        local p, a, b = cuts[i], cuts[math.max(1, i - 1)], cuts[math.min(#cuts, i + 1)]
        local dx, dy = b[1] - a[1], b[2] - a[2]
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 1e-6 then dx, dy, len = 0.0, 1.0, 1.0 end
        dx, dy = dx / len, dy / len
        local w = half
        if i > 1 and i < #cuts then
            local ix, iy = p[1] - a[1], p[2] - a[2]
            local il = math.sqrt(ix * ix + iy * iy)
            if il > 1e-6 then w = half / math.max(0.5, (ix * dx + iy * dy) / il) end
        end
        local rx, ry = dy, -dx   -- its right, looking the way the car went
        joints[i] = { l = { x = p[1] - rx * w, y = p[2] - ry * w, z = p[3] },
                      r = { x = p[1] + rx * w, y = p[2] + ry * w, z = p[3] }, v = p[4] }
    end
    local pieces = {}
    for from = 1, #joints - 1, LINE_PIECE do
        local to = math.min(from + LINE_PIECE - 1, #joints - 1)
        local sx, sy, sz, k = 0.0, 0.0, 0.0, 0
        for i = from, to + 1 do
            local c = cuts[i]
            sx, sy, sz, k = sx + c[1], sy + c[2], sz + c[3], k + 1
        end
        sx, sy, sz = sx / k, sy / k, sz / k
        local r = 0.0
        for i = from, to + 1 do
            local c = cuts[i]
            local d = math.sqrt((c[1] - sx) ^ 2 + (c[2] - sy) ^ 2 + (c[3] - sz) ^ 2)
            if d > r then r = d end
        end
        pieces[#pieces + 1] = { from = from, to = to, x = sx, y = sy, z = sz, r = r + LINE_W }
    end
    return joints, pieces
end

local function drawPath()
    if drawing then return end
    drawing = true
    CreateThread(function()
        while path and FurnishBuilder.open() do
            -- Its car not selected: nothing drawn, so nothing to do every frame
            if FurnishBuilder.selectedId() ~= path.car then
                Wait(250)
            elseif linePage:up() then
                local cam = GetFinalRenderedCamCoord()
                local j = path.joints
                for _, c in ipairs(path.pieces) do
                    local dx, dy, dz = c.x - cam.x, c.y - cam.y, c.z - cam.z
                    local reach = LINE_NEAR_M + c.r
                    if dx * dx + dy * dy + dz * dz <= reach * reach then
                        for i = c.from, c.to do
                            -- (The top of the tile, where its chevrons point, at the end the car went on to.)
                            local a, b = j[i], j[i + 1]
                            WorldQuad.drawCorners(LINE_TXD, LINE_TEX, b.l, b.r, a.l, a.r, 0.0, 0.0, 1.0, b.v, 235, 255, 255, 255)
                        end
                    end
                end
                Wait(0)
            else
                Wait(100)   -- (its browser still coming up: nothing to draw with yet)
            end
        end
        drawing = false
        if not FurnishBuilder.open() then path = nil end
        if not path then lineRelease() end
    end)
end

--- A car's take's line on the ground (drawn while that car is selected), or none (`id` nil).
local function showPath(id, car)
    pathWant = id
    if not id or type(car) ~= 'string' then
        path, pathWant = nil, nil
        if not drawing then lineRelease() end   -- (a loop drawing lets it go as it ends)
        return
    end
    if path and path.take == id then path.car = car return end   -- (shown already)
    lineAttach()
    CreateThread(function()
        local samples = TakePlayer.fetch(id)
        if not samples or pathWant ~= id then
            if not path and not drawing then lineRelease() end
            return
        end
        local joints, pieces = lineOf(samples)
        if not joints then
            path = nil
            if not drawing then lineRelease() end
            return
        end
        path = { take = id, car = car, joints = joints, pieces = pieces }
        drawPath()
    end)
end

-- ---- the page ----

RegisterNUICallback('directorPreviewPlay', function(d, cb)
    cb('ok')
    if type(d) == 'table' then CreateThread(function() play(d.runs) end) end
end)

RegisterNUICallback('directorPreviewStop', function(_, cb)
    cb('ok')
    stop()
    say('idle')
end)

RegisterNUICallback('directorPreviewPath', function(d, cb)
    cb('ok')
    local id = type(d) == 'table' and math.tointeger(tonumber(d.take)) or nil
    showPath(id, type(d) == 'table' and d.car or nil)
end)
