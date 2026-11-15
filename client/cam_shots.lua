-- ============================================
-- CamShots — where each kind of shot puts the camera
-- ============================================
--
-- A SHOT says where the camera is and where it looks, one of five ways:
--
--   fixed     a place and a turn in the world: the free camera's shot
--   orbit     round a SUBJECT (a car, a person, a prop, a point), at an angle, a height and a distance,
--             looking at a point on it; `fit` measures the distance in "fills the screen", so one orbit
--             frames a bike and a bus alike (whip_autos' showroom framing); `turn` spins it slowly
--   chase     behind a moving subject on a spring: it leans into slides, looks
--             ahead, pulls in when a wall is in the way, and widens with speed
--   mounted   fixed to a subject: a bonnet, a bumper, a shoulder
--   track     stands in one place and turns to keep a subject in frame
--
-- A SUBJECT is a name: 'player' (you), 'vehicle' (the car you are in, or were last in), or a name the
-- caller hands an entity or a point for (PlayCameraSequence's `subjects`). A subject that has gone
-- answers nil, and the sequence holds the camera where it last was.
--
-- A pose is { x, y, z, pitch, roll, yaw, fov } in GTA's camera rotation (shared/cam_math.lua), with
-- `ax, ay, az` and `subject` when it looks at a subject (a move between two such shots keeps looking).

CamShots = {}

local M = CamMath
local clamp, damp, dampAngle, lerp = M.clamp, M.damp, M.dampAngle, M.lerp
local localToWorld, worldToLocal, rotFromDir = M.localToWorld, M.worldToLocal, M.rotFromDir
local abs, sqrt, cos, sin, rad, deg = math.abs, math.sqrt, math.cos, math.sin, math.rad, math.deg

-- A point subject's box: a metre each way, so `fit` and `aim` mean something round a place too.
local POINT_MIN, POINT_MAX = { x = -0.5, y = -0.5, z = -0.5 }, { x = 0.5, y = 0.5, z = 0.5 }

-- ============================================
-- Subjects
-- ============================================

local dims = {}   -- [model] = { min, max }: a model's box never changes

local function modelBox(ent)
    local model = GetEntityModel(ent)
    local d = dims[model]
    if not d then
        local mn, mx = GetModelDimensions(model)
        d = { { x = mn.x, y = mn.y, z = mn.z }, { x = mx.x, y = mx.y, z = mx.z } }
        dims[model] = d
    end
    return d[1], d[2]
end

--- A built-in subject's entity, now.
local function builtIn(name)
    local ped = PlayerPedId()
    if name == 'player' then return ped end
    if name == 'vehicle' then
        local veh = GetVehiclePedIsIn(ped, false)
        if veh == 0 then veh = GetVehiclePedIsIn(ped, true) end
        return veh ~= 0 and veh or nil
    end
    return nil
end

--- What a subject name stands for this frame: { ent?, x, y, z, h, min, max, vx, vy, vz }, or nil when it
--- is not there. Looked up once a frame per run (run.frame).
---@param run table
---@param name string
---@return table|nil
function CamShots.subject(run, name)
    if type(name) ~= 'string' then return nil end
    run.subjectCache = run.subjectCache or {}
    local c = run.subjectCache[name]
    if c and c.frame == run.frame then return c.s end

    local given = run.subjects and run.subjects[name]
    local ent = nil
    local s = nil
    if type(given) == 'number' then
        ent = given
    elseif type(given) == 'table' or type(given) == 'vector3' or type(given) == 'vector4' then
        if tonumber(given.x) and tonumber(given.y) and tonumber(given.z) then
            s = { x = given.x + 0.0, y = given.y + 0.0, z = given.z + 0.0, h = tonumber(given.w or given.h) or 0.0,
                  min = POINT_MIN, max = POINT_MAX, vx = 0.0, vy = 0.0, vz = 0.0 }
        end
    elseif given == nil then
        ent = builtIn(name)
    end
    if ent and ent ~= 0 and DoesEntityExist(ent) then
        local p = GetEntityCoords(ent)
        local v = GetEntityVelocity(ent)
        local mn, mx = modelBox(ent)
        s = { ent = ent, x = p.x, y = p.y, z = p.z, h = GetEntityHeading(ent), min = mn, max = mx,
              vx = v.x, vy = v.y, vz = v.z }
    end
    run.subjectCache[name] = { frame = run.frame, s = s }
    return s
end

--- The point a shot looks at: a share of the subject's box (aim -1..1 on each axis, 0 the centre, +y the
--- front, +z the top, +x the right), in the subject's own metres.
---@return number right, number fwd, number up
function CamShots.aimLocal(s, aim)
    local mn, mx = s.min, s.max
    aim = aim or {}
    return (mn.x + mx.x) * 0.5 + (tonumber(aim.x) or 0.0) * (mx.x - mn.x) * 0.5,
           (mn.y + mx.y) * 0.5 + (tonumber(aim.y) or 0.0) * (mx.y - mn.y) * 0.5,
           (mn.z + mx.z) * 0.5 + (tonumber(aim.z) or 0.0) * (mx.z - mn.z) * 0.5
end

--- The other way: a point in the subject's metres as a share of its box.
function CamShots.aimShare(s, right, fwd, up)
    local mn, mx = s.min, s.max
    local function share(v, lo, hi)
        local half = (hi - lo) * 0.5
        if half < 0.001 then return 0.0 end
        return (v - (lo + hi) * 0.5) / half
    end
    return { x = share(right, mn.x, mx.x), y = share(fwd, mn.y, mx.y), z = share(up, mn.z, mx.z) }
end

--- The screen's width over its height.
local function aspect()
    local w, h = GetActiveScreenResolution()
    if h and h > 0 then return w / h end
    return 16.0 / 9.0
end

--- The distance from the subject's box centre at which the whole box is on screen, the camera looking
--- along (pitch, yaw).
function CamShots.fitDistance(s, lookPitch, lookYaw, fov)
    local mn, mx = s.min, s.max
    local corners = {}
    for _, lx in ipairs({ mn.x, mx.x }) do
        for _, ly in ipairs({ mn.y, mx.y }) do
            for _, lz in ipairs({ mn.z, mx.z }) do
                local x, y, z = localToWorld(s.x, s.y, s.z, s.h, lx, ly, lz)
                corners[#corners + 1] = { x = x, y = y, z = z }
            end
        end
    end
    local cx, cy, cz = localToWorld(s.x, s.y, s.z, s.h, (mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5, (mn.z + mx.z) * 0.5)
    local right, up, fwd = M.basis(lookPitch, lookYaw)
    local tanV, tanH = M.tangents(fov, aspect())
    return M.fitDistance(corners, cx, cy, cz, tanV, tanH, right, up, fwd)
end

-- ============================================
-- Orbit
-- ============================================
--
-- yaw    degrees round from the subject's back: 0 behind it, 90 on its left side... measured as its
--        heading turns (counter-clockwise from above), 180 in front
-- pitch  degrees above it (negative: below)
-- dist   metres from the point looked at; or `fit`, a multiple of the distance that fills the screen
-- aim    the point looked at, a share of its box; `look` = { pitch, yaw } turns the view off that point
-- turn   degrees a second it drifts round while the shot runs; `clear` keeps it this far off the ground

--- An orbit's numbers at shot time `ts` seconds, the distance in metres: what a move between two orbits
--- of one subject blends. `ctl` is a viewer's own turn and zoom (an orbit camera with control).
function CamShots.orbitParams(shot, s, ts, ctl)
    local fov = shot.fov or 50.0
    local yaw = (shot.yaw or 0.0) + (shot.turn or 0.0) * ts + (ctl and ctl.yaw or 0.0)
    local pitch = clamp((shot.pitch or 0.0) + (ctl and ctl.pitch or 0.0), -80.0, 85.0)
    local ar, af, au = CamShots.aimLocal(s, shot.aim)
    local dist
    if shot.fit then
        -- Measured from the box: the camera looks at the subject from (yaw, pitch).
        dist = CamShots.fitDistance(s, -pitch, s.h + yaw, fov) * shot.fit
    else
        dist = shot.dist or 5.0
    end
    dist = math.max(dist * (ctl and ctl.zoom or 1.0), 0.3)
    local look = shot.look or {}
    return { yaw = M.wrap180(yaw), pitch = pitch, dist = dist, ar = ar, af = af, au = au,
             lp = look.pitch or 0.0, ly = look.yaw or 0.0, fov = fov, roll = shot.roll or 0.0, clear = shot.clear }
end

--- Where an orbit's numbers put the camera round subject `s`.
function CamShots.orbitPose(s, P, subjectName)
    local ax, ay, az = localToWorld(s.x, s.y, s.z, s.h, P.ar, P.af, P.au)
    local h = s.h + P.yaw
    local pr = rad(P.pitch)
    local cx, cy, cz = localToWorld(ax, ay, az, h, 0.0, -P.dist * cos(pr), P.dist * sin(pr))
    local clear = P.clear
    if clear == nil then clear = 0.35 end
    if clear > 0.0 then
        local ok, gz = GetGroundZFor_3dCoord(cx, cy, cz + 2.0, false)
        if ok and cz < gz + clear then cz = gz + clear end
    end
    local pitch, yaw = rotFromDir(ax - cx, ay - cy, az - cz)
    return { x = cx, y = cy, z = cz, pitch = clamp(pitch + P.lp, -89.0, 89.0), roll = P.roll, yaw = yaw + P.ly,
             fov = P.fov, ax = ax, ay = ay, az = az, subject = subjectName }
end

-- ============================================
-- Chase
-- ============================================
--
-- dist, height   behind and above the subject     ahead   metres the view leads along its travel
-- slip           0 follow its nose, 1 follow where it is going (most of how the chase feels)
-- stiff          how tightly it follows (a spring's rate)   fovAdd  degrees wider at full speed
-- collision      pull in when something is between the camera and the subject (default on)
-- tilt           degrees it looks up past the subject (1.5; the driving camera's director changes it)

local REF_SPEED, SPEED_CURVE = 62.0, 1.35   -- m/s counted as flat out, and how late the effects come in
local FEED_FORWARD = 0.88                   -- cancels a spring's lag behind something moving steadily

local function speedShare(s)
    local sp = sqrt(s.vx * s.vx + s.vy * s.vy + s.vz * s.vz)
    return clamp(sp / REF_SPEED, 0.0, 1.0) ^ SPEED_CURVE, sp
end

--- A chase shot this frame. Keeps its spring in `mem`; `dt` seconds since the last frame (large to snap).
--- `look` = { yaw, pitch, amount, free }: a viewer looking round it (the driving camera): the camera swings
--- round the car by yaw and up and over it by pitch, the look-ahead fades by `amount` (0..1), and while
--- `free` it answers the hand rather than trailing on its springs.
function CamShots.chase(shot, s, mem, dt, subjectName, look)
    local visual, speed = speedShare(s)
    local ax, ay, az = s.x, s.y, s.z + 0.55

    -- Lean towards where it is going.
    local velH = (speed > 1.0) and deg(math.atan(-s.vx, s.vy)) or s.h
    local fx, fy = -sin(rad(s.h)), cos(rad(s.h))
    local slipDeg = 0.0
    if speed > 1.0 and (s.vx * fx + s.vy * fy) > 0.0 then
        slipDeg = clamp(M.wrap180(velH - s.h), -120.0, 120.0)
    end
    local orbitYaw = lerp(s.h, M.nearestAngle(s.h, velH), (shot.slip or 0.35) * clamp(abs(slipDeg) / 45.0, 0.0, 1.0))
    orbitYaw = orbitYaw + (look and look.yaw or 0.0)

    local dist = (shot.dist or 5.0) + (shot.distAdd or 1.0) * visual
    -- Looking up or down swings the camera along an arc round the car, so the car stays framed.
    local op = rad(look and look.pitch or 0.0)
    local tx, ty, tz = localToWorld(ax, ay, az, orbitYaw, 0.0, -dist * cos(op), (shot.height or 1.8) + dist * sin(op))
    local stiff = shot.stiff or 7.0
    if look and look.free then stiff = math.max(stiff, 12.0) end
    tx, ty, tz = tx + s.vx * FEED_FORWARD / stiff, ty + s.vy * FEED_FORWARD / stiff, tz + s.vz * FEED_FORWARD / stiff

    local lead = (shot.ahead or 3.5) * visual * (1.0 - (look and look.amount or 0.0))
    local lx, ly, lz = ax, ay, az + 0.35
    if speed > 1.0 then lx, ly = lx + s.vx / speed * lead, ly + s.vy / speed * lead end

    if not mem.init or dt > 0.5 then
        mem.x, mem.y, mem.z = tx, ty, tz
    else
        mem.x, mem.y, mem.z = damp(mem.x, tx, stiff, dt), damp(mem.y, ty, stiff, dt), damp(mem.z, tz, stiff, dt)
    end

    local cx, cy, cz = mem.x, mem.y, mem.z
    if shot.collision ~= false and s.ent then
        local h = StartExpensiveSynchronousShapeTestLosProbe(ax, ay, az + 0.2, cx, cy, cz, 1 + 16, s.ent, 4)
        local _, hit, at = GetShapeTestResult(h)
        if hit == 1 or hit == true then
            local dx, dy, dz = at.x - ax, at.y - ay, at.z - az
            local len = sqrt(dx * dx + dy * dy + dz * dz)
            if len > 1e-3 then
                local pull = math.max(len - 0.35, 1.6) / len
                cx, cy, cz = ax + dx * pull, ay + dy * pull, az + dz * pull
            end
        end
    end

    local pitch, yaw = rotFromDir(lx - cx, ly - cy, lz - cz)
    pitch = pitch + (shot.tilt or 1.5)
    local rotRate = (shot.turnRate or 7.0)
    if look and look.free then rotRate = math.max(rotRate, 12.0) end
    local fovWant = (shot.fov or 50.0) + (shot.fovAdd or 8.0) * visual
    local rollWant = -clamp(slipDeg / 45.0, -1.0, 1.0) * 2.5
    if not mem.init or dt > 0.5 then
        mem.pitch, mem.yaw, mem.fov, mem.roll = pitch, yaw, fovWant, rollWant
    else
        mem.pitch = damp(mem.pitch, pitch, rotRate, dt)
        mem.yaw = dampAngle(mem.yaw, yaw, rotRate, dt)
        mem.fov = damp(mem.fov, fovWant, 3.5, dt)
        mem.roll = damp(mem.roll, rollWant, 4.0, dt)
    end
    mem.init = true
    return { x = cx, y = cy, z = cz, pitch = mem.pitch, roll = mem.roll, yaw = mem.yaw, fov = mem.fov,
             ax = lx, ay = ly, az = lz, subject = subjectName }
end

-- ============================================
-- Mounted
-- ============================================
--
-- offset  metres from the subject's origin, in its own axes (x right, y forward, z up)
-- rot     the turn relative to the subject (x pitch, y roll, z yaw): it tilts and rolls with a car

function CamShots.mounted(shot, s)
    local o, r = shot.offset or {}, shot.rot or {}
    local ox, oy, oz = tonumber(o.x) or 0.0, tonumber(o.y) or 0.0, tonumber(o.z) or 0.0
    local rp, rr, ry = tonumber(r.x) or 0.0, tonumber(r.y) or 0.0, tonumber(r.z) or 0.0
    if s.ent then
        local p = GetOffsetFromEntityInWorldCoords(s.ent, ox, oy, oz)
        local er = GetEntityRotation(s.ent, 2)
        local q = M.quatMul(M.quatFromEuler(er.x, er.y, er.z), M.quatFromEuler(rp, rr, ry))
        local pitch, roll, yaw = M.quatToEuler(q)
        return { x = p.x, y = p.y, z = p.z, pitch = pitch, roll = roll, yaw = yaw, fov = shot.fov or 50.0 }
    end
    local x, y, z = localToWorld(s.x, s.y, s.z, s.h, ox, oy, oz)
    return { x = x, y = y, z = z, pitch = rp, roll = rr, yaw = M.wrap180(s.h + ry), fov = shot.fov or 50.0 }
end

-- ============================================
-- Places in the world, or round the sequence's anchor
-- ============================================
--
-- A sequence with an `anchor` keeps its fixed places relative to that subject as it stood when the
-- sequence started (x right, y forward, z up, and a yaw from its heading): an intro made round one car
-- plays round any car, anywhere.

local function placeOf(pos, anchor)
    local x, y, z = tonumber(pos.x) or 0.0, tonumber(pos.y) or 0.0, tonumber(pos.z) or 0.0
    if anchor then return localToWorld(anchor.x, anchor.y, anchor.z, anchor.h, x, y, z) end
    return x, y, z
end

function CamShots.fixed(shot, anchor)
    local x, y, z = placeOf(shot.pos or {}, anchor)
    local r = shot.rot or {}
    local yaw = tonumber(r.z) or 0.0
    if anchor then yaw = yaw + anchor.h end
    return { x = x, y = y, z = z, pitch = tonumber(r.x) or 0.0, roll = tonumber(r.y) or 0.0, yaw = M.wrap180(yaw),
             fov = shot.fov or 50.0 }
end

--- Track: stands at `pos` and looks at `aim` on the subject (a share of its box), turned off it by `look`.
function CamShots.track(shot, s, anchor, subjectName)
    local x, y, z = placeOf(shot.pos or {}, anchor)
    local ar, af, au = CamShots.aimLocal(s, shot.aim)
    local ax, ay, az = localToWorld(s.x, s.y, s.z, s.h, ar, af, au)
    local pitch, yaw = rotFromDir(ax - x, ay - y, az - z)
    local look = shot.look or {}
    return { x = x, y = y, z = z, pitch = clamp(pitch + (look.pitch or 0.0), -89.0, 89.0), roll = shot.roll or 0.0,
             yaw = yaw + (look.yaw or 0.0), fov = shot.fov or 50.0, ax = ax, ay = ay, az = az, subject = subjectName }
end

-- ============================================
-- One shot
-- ============================================

--- Where `shot` puts the camera now. `ts` the seconds since its key, `mem` the key's own memory (a chase's
--- spring), `dt` the seconds since the last frame. nil when its subject is not there.
---@return table|nil pose
function CamShots.evaluate(run, shot, ts, mem, dt)
    local kind = shot.kind
    if kind == 'fixed' then return CamShots.fixed(shot, run.anchor) end
    local s = CamShots.subject(run, shot.subject)
    if not s then return nil end
    if kind == 'orbit' then return CamShots.orbitPose(s, CamShots.orbitParams(shot, s, ts, run.ctl), shot.subject) end
    if kind == 'track' then return CamShots.track(shot, s, run.anchor, shot.subject) end
    if kind == 'mounted' then return CamShots.mounted(shot, s) end
    if kind == 'chase' then return CamShots.chase(shot, s, mem, dt, shot.subject) end
    return nil
end

-- ============================================
-- From a camera to a shot (the editor)
-- ============================================
--
-- The Camera Creator flies a free camera and turns where it is into the kind of shot asked for, round
-- the subject asked for. These are the evaluations above run backwards.

--- An orbit that puts the camera where it is now, looking where the shot's aim is.
---@param s table  the subject (CamShots.subject)
---@param cam table { x, y, z, pitch, yaw, fov }
---@param aim table|nil  a share of the box (default the centre)
---@param useFit boolean  measure the distance as `fit` (default) or metres
function CamShots.orbitFromCamera(s, cam, aim, useFit)
    aim = aim or { x = 0.0, y = 0.0, z = 0.0 }
    local ar, af, au = CamShots.aimLocal(s, aim)
    local ax, ay, az = localToWorld(s.x, s.y, s.z, s.h, ar, af, au)
    local dx, dy, dz = cam.x - ax, cam.y - ay, cam.z - az
    local dist = math.max(sqrt(dx * dx + dy * dy + dz * dz), 0.3)
    local pitch = math.deg(math.asin(clamp(dz / dist, -1.0, 1.0)))
    -- The camera is behind the bearing it stands at: from the aim point out to the camera is the
    -- bearing's backward direction, so the bearing is the direction from the camera to the aim point.
    local h = deg(math.atan(dx, -dy))   -- heading whose backward vector points at the camera
    local yaw = M.wrap180(h - s.h)
    -- What is left of where the camera looks, past looking straight at the point, is the look nudge.
    local lp, ly = rotFromDir(-dx, -dy, -dz)
    local shot = { kind = 'orbit', yaw = M.round(yaw, 2), pitch = M.round(pitch, 2), aim = aim,
                   fov = M.round(cam.fov or 50.0, 2),
                   look = { pitch = M.round((cam.pitch or lp) - lp, 2), yaw = M.round(M.wrap180((cam.yaw or ly) - ly), 2) } }
    if useFit ~= false then
        local fit = CamShots.fitDistance(s, -pitch, s.h + yaw, shot.fov)
        shot.fit = M.round(dist / fit, 3)
    else
        shot.dist = M.round(dist, 3)
    end
    return shot
end

--- A mounted shot that holds the camera where it is now relative to the subject.
function CamShots.mountedFromCamera(s, cam)
    if s.ent then
        local off = GetOffsetFromEntityGivenWorldCoords(s.ent, cam.x, cam.y, cam.z)
        local er = GetEntityRotation(s.ent, 2)
        local qe = M.quatFromEuler(er.x, er.y, er.z)
        local qc = M.quatFromEuler(cam.pitch or 0.0, cam.roll or 0.0, cam.yaw or 0.0)
        local rel = M.quatMul({ qe[1], -qe[2], -qe[3], -qe[4] }, qc)
        local p, r, y = M.quatToEuler(rel)
        return { kind = 'mounted', offset = { x = M.round(off.x, 3), y = M.round(off.y, 3), z = M.round(off.z, 3) },
                 rot = { x = M.round(p, 2), y = M.round(r, 2), z = M.round(y, 2) }, fov = M.round(cam.fov or 50.0, 2) }
    end
    local r, f, u = worldToLocal(s.x, s.y, s.z, s.h, cam.x, cam.y, cam.z)
    return { kind = 'mounted', offset = { x = M.round(r, 3), y = M.round(f, 3), z = M.round(u, 3) },
             rot = { x = M.round(cam.pitch or 0.0, 2), y = M.round(cam.roll or 0.0, 2), z = M.round(M.wrap180((cam.yaw or 0.0) - s.h), 2) },
             fov = M.round(cam.fov or 50.0, 2) }
end

--- A place as the sequence keeps it: the world, or round the anchor.
function CamShots.placeFromWorld(x, y, z, anchor)
    if anchor then
        local r, f, u = worldToLocal(anchor.x, anchor.y, anchor.z, anchor.h, x, y, z)
        return { x = M.round(r, 3), y = M.round(f, 3), z = M.round(u, 3) }
    end
    return { x = M.round(x, 3), y = M.round(y, 3), z = M.round(z, 3) }
end

--- A fixed shot where the camera is now.
function CamShots.fixedFromCamera(cam, anchor)
    local yaw = cam.yaw or 0.0
    if anchor then yaw = yaw - anchor.h end
    return { kind = 'fixed', pos = CamShots.placeFromWorld(cam.x, cam.y, cam.z, anchor),
             rot = { x = M.round(cam.pitch or 0.0, 2), y = M.round(cam.roll or 0.0, 2), z = M.round(M.wrap180(yaw), 2) },
             fov = M.round(cam.fov or 50.0, 2) }
end

--- A track shot where the camera is now, looking at the subject's aim point (the camera's own turn
--- past that is the look nudge).
function CamShots.trackFromCamera(s, cam, aim, anchor)
    aim = aim or { x = 0.0, y = 0.0, z = 0.0 }
    local ar, af, au = CamShots.aimLocal(s, aim)
    local ax, ay, az = localToWorld(s.x, s.y, s.z, s.h, ar, af, au)
    local lp, ly = rotFromDir(ax - cam.x, ay - cam.y, az - cam.z)
    return { kind = 'track', pos = CamShots.placeFromWorld(cam.x, cam.y, cam.z, anchor), aim = aim,
             look = { pitch = M.round((cam.pitch or lp) - lp, 2), yaw = M.round(M.wrap180((cam.yaw or ly) - ly), 2) },
             roll = M.round(cam.roll or 0.0, 2), fov = M.round(cam.fov or 50.0, 2) }
end

--- Forget the models' boxes (a model streamed later than asked can answer a zero box first).
function CamShots.forgetBoxes() dims = {} end
