-- ============================================
-- CamSequence — a timeline of shots, and the camera at any moment of it
-- ============================================
--
-- A SEQUENCE is the Camera Creator's timeline as data (the same data a script plays, or the server
-- keeps by name):
--
--   {
--       name = 'intro', length = 12000,      -- milliseconds (default: the last key's time)
--       anchor = 'vehicle',                  -- optional: fixed places are kept round this subject
--       loop = false, letterbox = false,
--       ease = 'linear',                     -- the whole timeline's own speed curve (old paths: 'smooth')
--       keys = {
--           { t = 0, shot = { kind = 'fixed', pos = { x, y, z }, rot = { x, y, z }, fov = 50 },
--             move = 'glide', ease = 'smooth' },
--           { t = 4000, shot = { kind = 'orbit', subject = 'vehicle', yaw = 30, pitch = 10, fit = 1.2,
--                                aim = { x = 0, y = 0, z = 0.5 }, fov = 40, turn = 6 },
--             move = 'cut', shake = { amount = 0.3, freq = 6 }, filter = 'NG_filmic04',
--             punch = { fov = 8, decay = 4 } },
--       },
--   }
--
-- A KEY is a shot at a time, and how the camera goes from it to the next key (`move`):
--
--   cut      stays on this shot, then jumps to the next at its time
--   glide    a smooth curve to the next key, turning smoothly too. GLIDING KEYS IN A ROW ARE ONE MOVE:
--            the camera flows through the keys between at speed, never stopping (still at each key at its
--            time), and the first key's `ease` says how the whole glide starts and ends
--   spring   nfsmw's feel: quick at first, settling into the next shot (`rate`, about 3 gentle to 8 brisk)
--   orbit    between two orbits of one subject: swings round it instead of cutting across
--
-- A move between two shots that both look at one subject keeps looking at it all the way. An orbit swing
-- goes round the short way, or `around = 'left'` / `'right'`.
--
-- On a key, as layers: `shake` (a camera in hands: degrees, and how quick), `filter` (a timecycle look,
-- from that key on), `punch` (a kick of the lens at that key, wider for + and tighter for -, fading at
-- `decay`). Shake blends from key to key along a move.
--
-- WEIGHT (`coast` on a key the camera stops at — the last key, or one whose move is a cut): the camera is
-- heavy. It arrives at the speed it was going, does not brake for the key, and carries on past it along
-- the way it was going (and turning, and zooming), slowing as if its push had stopped. `coast` is the
-- resistance, 0.2 to 50: low goes far, high stops soon — it carries on its speed divided by the
-- resistance (10 m/s at 2: 5 metres), most of that in the first 1 / resistance seconds.
--
-- THE SAME MOMENT IS ALWAYS THE SAME PICTURE (scrubbing): everything is worked out from the time, except
-- what moves by itself in the world (the subjects) and a chase's spring.

CamSequence = {}

local M = CamMath

CamSequence.KINDS = { 'fixed', 'orbit', 'chase', 'mounted', 'track' }
CamSequence.MOVES = { 'cut', 'glide', 'spring', 'orbit' }
CamSequence.MAX_KEYS = 200
CamSequence.MAX_LENGTH = 30 * 60 * 1000

local IS_KIND, IS_MOVE = {}, {}
for _, k in ipairs(CamSequence.KINDS) do IS_KIND[k] = true end
for _, k in ipairs(CamSequence.MOVES) do IS_MOVE[k] = true end

-- ============================================
-- Checking a sequence
-- ============================================

local function isNum(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end

--- A number in range, or the default when it is not given. Answers the number, or nil and why.
local function num(v, lo, hi, default, what)
    if v == nil then return default end
    v = tonumber(v)
    if not isNum(v) then return nil, what .. ' must be a number' end
    if v < lo or v > hi then return nil, ('%s must be between %s and %s'):format(what, lo, hi) end
    return v + 0.0
end

local function vec(v, what, limit)
    local t = type(v)
    if t ~= 'table' and t ~= 'vector3' and t ~= 'vector4' then return nil, what .. ' must be { x, y, z }' end
    limit = limit or 100000.0
    local out = {}
    for _, a in ipairs({ 'x', 'y', 'z' }) do
        local n = tonumber(v[a])
        if not isNum(n) or n < -limit or n > limit then return nil, ('%s.%s must be a number'):format(what, a) end
        out[a] = n + 0.0
    end
    return out
end

local function subjectName(v, what)
    if type(v) ~= 'string' or not v:match('^[%w_]+$') or #v > 32 then
        return nil, what .. ' must be a subject name (player, vehicle, or one you pass in subjects)'
    end
    return v
end

--- Each field a kind takes: [field] = { checker, ... }. Unknown fields are left out.
local function cleanShot(s, where)
    if type(s) ~= 'table' then return nil, where .. ': a shot is a table' end
    local kind = s.kind
    if not IS_KIND[kind] then return nil, where .. ': kind must be fixed, orbit, chase, mounted or track' end
    local out = { kind = kind }
    local why
    out.fov, why = num(s.fov, 1.0, 130.0, 50.0, where .. ' fov'); if why then return nil, why end
    out.roll, why = num(s.roll, -180.0, 180.0, nil, where .. ' roll'); if why then return nil, why end

    if kind ~= 'fixed' then
        out.subject, why = subjectName(s.subject, where .. ' subject'); if why then return nil, why end
    end
    if kind == 'fixed' or kind == 'track' then
        out.pos, why = vec(s.pos, where .. ' pos'); if why then return nil, why end
    end
    if kind == 'fixed' then
        out.rot, why = vec(s.rot or { x = 0, y = 0, z = 0 }, where .. ' rot', 720.0); if why then return nil, why end
    end
    if kind == 'orbit' or kind == 'track' then
        if s.aim ~= nil then out.aim, why = vec(s.aim, where .. ' aim', 10.0); if why then return nil, why end end
        if s.look ~= nil then
            if type(s.look) ~= 'table' then return nil, where .. ' look must be { pitch, yaw }' end
            local lp, ly
            lp, why = num(s.look.pitch, -90.0, 90.0, 0.0, where .. ' look.pitch'); if why then return nil, why end
            ly, why = num(s.look.yaw, -180.0, 180.0, 0.0, where .. ' look.yaw'); if why then return nil, why end
            out.look = { pitch = lp, yaw = ly }
        end
    end
    if kind == 'orbit' then
        out.yaw, why = num(s.yaw, -720.0, 720.0, 0.0, where .. ' yaw'); if why then return nil, why end
        out.pitch, why = num(s.pitch, -80.0, 85.0, 10.0, where .. ' pitch'); if why then return nil, why end
        out.fit, why = num(s.fit, 0.05, 20.0, nil, where .. ' fit'); if why then return nil, why end
        out.dist, why = num(s.dist, 0.3, 500.0, nil, where .. ' dist'); if why then return nil, why end
        if not out.fit and not out.dist then out.fit = 1.0 end
        out.turn, why = num(s.turn, -180.0, 180.0, nil, where .. ' turn'); if why then return nil, why end
        out.clear, why = num(s.clear, -1.0, 10.0, nil, where .. ' clear'); if why then return nil, why end
    end
    if kind == 'chase' then
        for _, f in ipairs({
            { 'dist', 0.5, 60.0 }, { 'height', -5.0, 30.0 }, { 'ahead', 0.0, 30.0 }, { 'slip', 0.0, 1.0 },
            { 'stiff', 0.5, 40.0 }, { 'turnRate', 0.5, 40.0 }, { 'fovAdd', -40.0, 60.0 }, { 'distAdd', -10.0, 20.0 },
        }) do
            out[f[1]], why = num(s[f[1]], f[2], f[3], nil, where .. ' ' .. f[1]); if why then return nil, why end
        end
        if s.collision ~= nil then out.collision = s.collision == true end
    end
    if kind == 'mounted' then
        out.offset, why = vec(s.offset or { x = 0, y = 0, z = 0 }, where .. ' offset', 200.0); if why then return nil, why end
        out.rot, why = vec(s.rot or { x = 0, y = 0, z = 0 }, where .. ' rot', 720.0); if why then return nil, why end
    end
    return out
end

--- Is `seq` one the camera can play? Answers a clean copy (keys in time order, defaults filled in,
--- unknown fields left out), or nil and why. Every way a sequence arrives goes through here: a
--- script's, the server's, the editor's.
---@param seq any
---@return table|nil seq
---@return string|nil why
function CamSequence.clean(seq)
    if type(seq) ~= 'table' then return nil, 'a sequence is a table with keys' end
    local out = {}
    local why
    if seq.name ~= nil then
        if type(seq.name) ~= 'string' or #seq.name > 60 then return nil, 'name: up to 60 characters' end
        out.name = seq.name
    end
    if seq.anchor ~= nil and seq.anchor ~= false then
        out.anchor, why = subjectName(seq.anchor, 'anchor'); if why then return nil, why end
    end
    out.loop = seq.loop == true
    out.letterbox = seq.letterbox == true
    out.ease = seq.ease or 'linear'
    if not M.isEase(out.ease) then return nil, 'ease must be linear, smooth, in, out or strong' end

    local keys = seq.keys
    if type(keys) ~= 'table' or #keys == 0 then return nil, 'a sequence needs at least one key' end
    if #keys > CamSequence.MAX_KEYS then return nil, ('%d keys at most'):format(CamSequence.MAX_KEYS) end
    out.keys = {}
    for i, k in ipairs(keys) do
        local where = ('key %d'):format(i)
        if type(k) ~= 'table' then return nil, where .. ' is not a table' end
        local key = {}
        key.t, why = num(k.t, 0, CamSequence.MAX_LENGTH, nil, where .. ' t'); if why then return nil, why end
        if not key.t then return nil, where .. ': t (milliseconds) is missing' end
        key.shot, why = cleanShot(k.shot, where); if why then return nil, why end
        key.move = k.move or 'glide'
        if not IS_MOVE[key.move] then return nil, where .. ': move must be cut, glide, spring or orbit' end
        key.ease = k.ease or 'smooth'
        if not M.isEase(key.ease) then return nil, where .. ': ease must be linear, smooth, in, out or strong' end
        key.rate, why = num(k.rate, 0.5, 30.0, nil, where .. ' rate'); if why then return nil, why end
        key.coast, why = num(k.coast, 0.2, 50.0, nil, where .. ' coast'); if why then return nil, why end
        if k.around ~= nil and k.around ~= 'short' then
            if k.around ~= 'left' and k.around ~= 'right' then return nil, where .. ': around must be short, left or right' end
            key.around = k.around
        end
        if k.shake ~= nil then
            local sh = type(k.shake) == 'table' and k.shake or { amount = k.shake }
            local amount, freq
            amount, why = num(sh.amount, 0.0, 10.0, 0.0, where .. ' shake amount'); if why then return nil, why end
            freq, why = num(sh.freq, 0.2, 40.0, 6.0, where .. ' shake freq'); if why then return nil, why end
            if amount > 0.0 then key.shake = { amount = amount, freq = freq } end
        end
        if k.filter ~= nil then
            if type(k.filter) ~= 'string' or not k.filter:match('^[%w_%-]+$') or #k.filter > 48 then
                return nil, where .. ': filter must be a timecycle name'
            end
            key.filter = k.filter
        end
        if k.punch ~= nil then
            if type(k.punch) ~= 'table' then return nil, where .. ': punch must be { fov, decay }' end
            local pf, pd
            pf, why = num(k.punch.fov, -60.0, 60.0, 0.0, where .. ' punch fov'); if why then return nil, why end
            pd, why = num(k.punch.decay, 0.2, 30.0, 4.0, where .. ' punch decay'); if why then return nil, why end
            if pf ~= 0.0 then key.punch = { fov = pf, decay = pd } end
        end
        if k.label ~= nil then
            if type(k.label) ~= 'string' or #k.label > 40 then return nil, where .. ': label is up to 40 characters' end
            key.label = k.label
        end
        out.keys[i] = key
    end
    -- In time order; keys at one time keep the order they came in.
    for i, k in ipairs(out.keys) do k._i = i end
    table.sort(out.keys, function(a, b) if a.t ~= b.t then return a.t < b.t end return a._i < b._i end)
    for _, k in ipairs(out.keys) do k._i = nil end

    local last = out.keys[#out.keys].t
    out.length, why = num(seq.length, 0, CamSequence.MAX_LENGTH, last, 'length'); if why then return nil, why end
    if out.length < last then out.length = last end
    return out
end

--- Every subject a sequence names (its anchor's too): { name = true }.
function CamSequence.subjectsOf(seq)
    local out = {}
    if seq.anchor then out[seq.anchor] = true end
    for _, k in ipairs(seq.keys) do
        if k.shot.subject then out[k.shot.subject] = true end
    end
    return out
end

-- ============================================
-- Playing it: a run
-- ============================================
--
-- A RUN is one playing of a sequence: what it was given (subjects), what it remembers (a chase's spring,
-- the anchor as it stood, the last good picture), and the frame it is on.

---@class CamRun
---@field seq table            the clean sequence it plays
---@field subjects table       names to entities or points
---@field mem table            [key] = what that key's shot remembers (a chase's spring)
---@field frame number         counts the frames, so each key is worked out once a frame
---@field anchor { x: number, y: number, z: number, h: number }|nil  the anchor subject as it stood (captureAnchor)
---@field last table|nil       the last good picture
---@field ctl table|nil        the viewer's turn and zoom, when they may steer (client/camera.lua)
---@field poses table|nil      this frame's key pictures (evaluate)
---@field subjectCache table|nil  this frame's subjects (client/cam_shots.lua)

--- A run of a clean sequence. `subjects` maps names to entities or points (PlayCameraSequence's).
---@return CamRun
function CamSequence.newRun(seq, subjects)
    return { seq = seq, subjects = subjects or {}, mem = {}, frame = 0, anchor = nil, last = nil, ctl = nil }
end

--- The anchor as it stands now, kept for the run (a sequence plays round where its subject WAS when it
--- started, not chasing it). Answers false when the anchor subject is not there.
function CamSequence.captureAnchor(run)
    local name = run.seq.anchor
    if not name then run.anchor = nil return true end
    run.frame = run.frame + 1
    local s = CamShots.subject(run, name)
    if not s then return false end
    run.anchor = { x = s.x, y = s.y, z = s.z, h = s.h }
    return true
end

--- A key's picture this frame (each key worked out once a frame, so a chase's spring steps once).
local function keyPose(run, i, tMs, dt)
    local cache = run.poses
    if cache[i] ~= nil then return cache[i] or nil end
    local k = run.seq.keys[i]
    local mem = run.mem[i]
    if not mem then mem = {}; run.mem[i] = mem end
    local p = CamShots.evaluate(run, k.shot, (tMs - k.t) / 1000.0, mem, dt)
    cache[i] = p or false
    return p
end

local function quatOf(p) return M.quatFromEuler(p.pitch, p.roll or 0.0, p.yaw) end

--- The two shots of a move both look at one subject: the camera keeps looking at it all the way.
local function lookTogether(a, b)
    return a.subject ~= nil and a.subject == b.subject and a.ax ~= nil and b.ax ~= nil
end

--- Finish a blended place: the turn either as blended (pitch, roll, yaw), or looking at the blended aim.
local function finish(x, y, z, pitch, roll, yaw, fov, a, b, e)
    if lookTogether(a, b) then
        local ax, ay, az = M.lerp(a.ax, b.ax, e), M.lerp(a.ay, b.ay, e), M.lerp(a.az, b.az, e)
        pitch, yaw = M.rotFromDir(ax - x, ay - y, az - z)
        -- What each shot turned off its subject (a nudge, a roll) blends along.
        local ap, ay2 = M.rotFromDir(a.ax - a.x, a.ay - a.y, a.az - a.z)
        local bp, by2 = M.rotFromDir(b.ax - b.x, b.ay - b.y, b.az - b.z)
        pitch = pitch + M.lerp(a.pitch - ap, b.pitch - bp, e)
        yaw = yaw + M.lerp(M.wrap180(a.yaw - ay2), M.wrap180(b.yaw - by2), e)
        roll = M.lerp(a.roll or 0.0, b.roll or 0.0, e)
    end
    return { x = x, y = y, z = z, pitch = M.clamp(pitch, -89.0, 89.0), roll = roll, yaw = M.wrap180(yaw), fov = fov }
end

-- ---- a glide of several keys ----

-- Paces that start, or end, at rest.
local RESTS_AT_START = { smooth = true, ['in'] = true, strong = true }
local RESTS_AT_END = { smooth = true, out = true, strong = true }

--- Key j glides on into key j + 1.
local function glidesOn(keys, j)
    local k, nk = keys[j], keys[j + 1]
    return k ~= nil and nk ~= nil and k.move == 'glide' and nk.t > k.t
end

--- A value along one stretch of a glide `h` seconds long, `u` of the way: from v1 to v2, leaving at slope
--- m1 and arriving at m2 (a second each).
local function through(v1, v2, m1, m2, h, u)
    local u2, u3 = u * u, u * u * u
    return (2.0 * u3 - 3.0 * u2 + 1.0) * v1 + (u3 - 2.0 * u2 + u) * h * m1
         + (-2.0 * u3 + 3.0 * u2) * v2 + (u3 - u2) * h * m2
end

--- The slopes a value leaves key a (v1, at t1) and arrives at key b (v2, at t2) with. Through a key, the
--- slope across it, from the key before to the key after: the same on both sides, so the camera keeps its
--- speed there. At the glide's start or end: none when its pace starts or ends at rest, else the stretch's.
local function slopes(v0, v1, v2, v3, t0, t1, t2, t3, restA, restB)
    local m1, m2
    if v0 then m1 = (v2 - v0) / (t2 - t0) elseif restA then m1 = 0.0 else m1 = (v2 - v1) / (t2 - t1) end
    if v3 then m2 = (v3 - v1) / (t3 - t1) elseif restB then m2 = 0.0 else m2 = (v2 - v1) / (t2 - t1) end
    return m1, m2
end


-- ---- weight: a camera that carries on past where it stops ----

local blend   -- the camera between two keys (below evaluate, which it serves)

local COAST_PROBE = 0.04   -- seconds before arriving at which the arrival speed is measured

--- A move into a weighted key does not brake for it: its pace's gentle start, if it has one, then on at
--- the move's own speed, so the camera arrives as fast as it was travelling.
local function arriving(pace, u)
    u = M.clamp(u, 0.0, 1.0)
    if pace == 'linear' or pace == 'out' then return u end
    return u * u * (2.0 - u)   -- from rest, arriving at the average speed (a slope of 1)
end

--- Does the camera stop at key `j` with weight: it has `coast`, a move arrives into it, and it holds there
--- (the last key, or its own move a cut)?
local function coastsAt(keys, j)
    local k = keys[j]
    if not k or not k.coast or j < 2 then return false end
    local before = keys[j - 1]
    if before.move == 'cut' or before.t >= k.t then return false end
    local after = keys[j + 1]
    return after == nil or k.move == 'cut' or after.t <= k.t
end

--- Key `j`'s held picture with the weight on it: the speed the camera arrived at (measured on the move into
--- it, a moment before the end), carried past the key and dying away, `tau` seconds after it arrived. Every
--- part carries on: where it is, the way it turns, the lens.
local function coastOn(run, j, pose, tau, t, dt)
    local keys = run.seq.keys
    local k, before = keys[j], keys[j - 1]
    local dur = (k.t - before.t) / 1000.0
    local du = math.min(COAST_PROBE / dur, 0.5)
    local pEnd = blend(run, j - 1, t, 1.0, dt)
    local pPrev = blend(run, j - 1, t, 1.0 - du, dt)
    if not pEnd or not pPrev then return pose end
    local h = du * dur
    local r = k.coast
    local carry = (1.0 - math.exp(-r * tau)) / r   -- seconds' worth of the arrival speed travelled so far
    local function v(a, b) return (a - b) / h * carry end
    return {
        x = pose.x + v(pEnd.x, pPrev.x), y = pose.y + v(pEnd.y, pPrev.y), z = pose.z + v(pEnd.z, pPrev.z),
        pitch = M.clamp(pose.pitch + v(pEnd.pitch, pPrev.pitch), -89.0, 89.0),
        roll = (pose.roll or 0.0) + v(pEnd.roll or 0.0, pPrev.roll or 0.0),
        yaw = M.wrap180(pose.yaw + M.wrap180(pEnd.yaw - pPrev.yaw) / h * carry),
        fov = M.clamp((pose.fov or 50.0) + v(pEnd.fov or 50.0, pPrev.fov or 50.0), 1.0, 130.0),
    }
end

--- The camera at `tMs` milliseconds: a pose { x, y, z, pitch, roll, yaw, fov } and its layers
--- { shake = { amount, freq }, filter, segment, key } — or nil when nothing can be shown (every subject
--- gone and nothing shown yet). `dt` is the seconds since the last frame (a large one snaps a chase).
---@param run table
---@param tMs number
---@param dt number|nil
---@return table|nil pose, table fx
function CamSequence.evaluate(run, tMs, dt)
    local seq = run.seq
    local keys = seq.keys
    local n = #keys
    run.frame = run.frame + 1
    run.poses = {}
    dt = dt or (1.0 / 60.0)

    local length = seq.length
    local t = M.clamp(tMs, 0.0, length)
    if seq.ease ~= 'linear' and length > 0 then t = length * M.ease(seq.ease, t / length) end

    -- The key whose stretch this is: the last one at or before t.
    local i = 1
    for j = 1, n do
        if keys[j].t <= t then i = j else break end
    end
    if t < keys[1].t then i = 1 end
    local k = keys[i]
    local nextKey = keys[i + 1]
    local fx = { key = i, filter = k.filter }

    local pose
    if not nextKey or k.move == 'cut' or nextKey.t <= k.t or t < k.t then
        -- Held on the last key past the end (an orbit left up): its own time runs on, so a turning
        -- orbit keeps turning.
        local tk = t
        if not nextKey and tMs > t then tk = tMs end
        pose = keyPose(run, i, tk, dt)
        if k.shake then fx.shake = { amount = k.shake.amount, freq = k.shake.freq } end
        -- Weight: arrived here moving, it carries on past the key.
        if pose and t >= k.t and coastsAt(keys, i) then pose = coastOn(run, i, pose, (tk - k.t) / 1000.0, t, dt) end
    else
        local u = (t - k.t) / (nextKey.t - k.t)
        local e, move
        pose, e, move = blend(run, i, t, u, dt)
        if e then fx.segment = { from = i, to = i + 1, u = u, e = e, move = move } end
        -- Shake blends along the move.
        local sa, sb = k.shake, nextKey.shake
        if sa or sb then
            local se = e or 0.0
            local amt = M.lerp(sa and sa.amount or 0.0, sb and sb.amount or 0.0, se)
            local freq = M.lerp(sa and sa.freq or (sb and sb.freq) or 6.0, sb and sb.freq or (sa and sa.freq) or 6.0, se)
            if amt > 0.0 then fx.shake = { amount = amt, freq = freq } end
        end
    end

    -- Nothing to show this frame (a subject gone): the last picture stands.
    if not pose then return run.last, fx end
    pose.fov = pose.fov or 50.0

    -- Lens punches: each key's, from its time on, fading.
    local punch = 0.0
    for j = 1, n do
        local pk = keys[j]
        if pk.t > t then break end
        if pk.punch then punch = punch + pk.punch.fov * math.exp(-pk.punch.decay * (t - pk.t) / 1000.0) end
    end
    if punch ~= 0.0 then pose.fov = M.clamp(pose.fov + punch, 1.0, 130.0) end

    run.last = pose
    return pose, fx
end

--- The camera between key `i` and the next, `u` of the way (time `t`): the pose, how far along it is for
--- what blends by share (`e`), and the move it made. nil when neither key's subject is there.
blend = function(run, i, t, u, dt)
    local keys = run.seq.keys
    local k, nextKey = keys[i], keys[i + 1]
    local a = keyPose(run, i, t, dt)
    local b = keyPose(run, i + 1, t, dt)
    if a and not b then return a end
    if b and not a then return b end
    if not (a and b) then return nil end
    local pose
    local move = k.move
    if move == 'orbit' and not (k.shot.kind == 'orbit' and nextKey.shot.kind == 'orbit'
        and k.shot.subject == nextKey.shot.subject) then
        move = 'glide'
    end
    local e
    if move == 'spring' then e = M.springEase(u, k.rate or 4.0)
    elseif coastsAt(keys, i + 1) then e = arriving(k.ease, u)   -- weighted: arrives at its speed
    else e = M.ease(k.ease, u) end

    if move == 'orbit' then
        local s = CamShots.subject(run, k.shot.subject)
        if s then
            local pa = CamShots.orbitParams(k.shot, s, (t - k.t) / 1000.0, run.ctl)
            local pb = CamShots.orbitParams(nextKey.shot, s, (t - nextKey.t) / 1000.0, run.ctl)
            -- Which way round: the short way, or the way the key says (left = counter-clockwise from
            -- above, as a heading turns).
            local d = M.wrap180(pb.yaw - pa.yaw)
            if k.around == 'left' and d < 0.0 then d = d + 360.0 end
            if k.around == 'right' and d > 0.0 then d = d - 360.0 end
            local P = {
                yaw = pa.yaw + d * e, pitch = M.lerp(pa.pitch, pb.pitch, e),
                dist = M.lerp(pa.dist, pb.dist, e), ar = M.lerp(pa.ar, pb.ar, e), af = M.lerp(pa.af, pb.af, e),
                au = M.lerp(pa.au, pb.au, e), lp = M.lerp(pa.lp, pb.lp, e), ly = M.lerp(pa.ly, pb.ly, e),
                fov = M.lerp(pa.fov, pb.fov, e), roll = M.lerp(pa.roll, pb.roll, e),
                clear = math.max(pa.clear or 0.35, pb.clear or 0.35),
            }
            pose = CamShots.orbitPose(s, P, k.shot.subject)
        else
            pose = a
        end
    elseif move == 'spring' then
        local pitch, roll, yaw = M.quatToEuler(M.quatSlerp(quatOf(a), quatOf(b), e))
        pose = finish(M.lerp(a.x, b.x, e), M.lerp(a.y, b.y, e), M.lerp(a.z, b.z, e), pitch, roll, yaw,
            M.lerp(a.fov, b.fov, e), a, b, e)
    else
        -- GLIDE. Gliding keys in a row are one move: it flows through the keys between (each at its
        -- time) at the speed across them, and starts and ends at its first key's pace. A glide of one
        -- stretch eases by its own pace, at an even speed along it.
        local inRun = k.move == 'glide'
        local hasPrev = inRun and i > 1 and glidesOn(keys, i - 1)
        local hasAfter = inRun and glidesOn(keys, i + 1)
        if not hasPrev and not hasAfter then
            -- One stretch is a straight line: at an even speed along it, its pace the only change of speed.
            local x, y, z = M.lerp(a.x, b.x, e), M.lerp(a.y, b.y, e), M.lerp(a.z, b.z, e)
            local pitch, roll, yaw = M.quatToEuler(M.quatSlerp(quatOf(a), quatOf(b), e))
            pose = finish(x, y, z, pitch, roll, yaw, M.lerp(a.fov, b.fov, e), a, b, e)
        else
            local first = i
            while first > 1 and glidesOn(keys, first - 1) do first = first - 1 end
            local runPace = keys[first].ease
            local restA = not hasPrev and RESTS_AT_START[runPace] == true
            local restB = not hasAfter and RESTS_AT_END[runPace] == true and not coastsAt(keys, i + 1)
            local p0 = hasPrev and keyPose(run, i - 1, t, dt) or nil
            local p3 = hasAfter and keyPose(run, i + 2, t, dt) or nil
            local t0 = hasPrev and keys[i - 1].t / 1000.0 or nil
            local t1, t2 = k.t / 1000.0, nextKey.t / 1000.0
            local t3 = hasAfter and keys[i + 2].t / 1000.0 or nil
            local function along(v0, v1, v2, v3)
                local m1, m2 = slopes(v0, v1, v2, v3, t0, t1, t2, t3, restA, restB)
                return through(v1, v2, m1, m2, t2 - t1, u)
            end
            local x = along(p0 and p0.x, a.x, b.x, p3 and p3.x)
            local y = along(p0 and p0.y, a.y, b.y, p3 and p3.y)
            local z = along(p0 and p0.z, a.z, b.z, p3 and p3.z)
            -- Headings unwrapped round this key's, so each turn goes the short way.
            local y1 = a.yaw
            local y2 = y1 + M.wrap180(b.yaw - a.yaw)
            local y0 = p0 and (y1 - M.wrap180(a.yaw - p0.yaw)) or nil
            local y3 = p3 and (y2 + M.wrap180(p3.yaw - b.yaw)) or nil
            local yaw = along(y0, y1, y2, y3)
            local pitch = along(p0 and p0.pitch, a.pitch, b.pitch, p3 and p3.pitch)
            local roll = along(p0 and (p0.roll or 0.0), a.roll or 0.0, b.roll or 0.0, p3 and (p3.roll or 0.0))
            local fov = along(p0 and p0.fov, a.fov, b.fov, p3 and p3.fov)
            -- How far along, for what blends by share (the look at a shared subject, shake).
            e = through(0.0, 1.0, (restA and 0.0 or 1.0), (restB and 0.0 or 1.0), 1.0, u)
            pose = finish(x, y, z, pitch, roll, yaw, fov, a, b, e)
        end
    end
    return pose, e, move
end

-- ============================================
-- Old paths, as sequences
-- ============================================

--- PlayCameraPath's points as a sequence: interpolate glides through them, at an even speed along the
--- whole path, with the path's ease over all of it; cycle cuts from one to the next.
---@return table|nil seq, string|nil why
function CamSequence.fromPath(opts)
    local points = opts.points
    if type(points) ~= 'table' or #points < 2 then return nil, 'a path needs at least 2 points' end
    local mode = opts.mode or 'interpolate'
    local keys = {}
    if mode == 'cycle' then
        local each = tonumber(opts.cycleDuration or 3000)
        for i, p in ipairs(points) do
            keys[i] = { t = (i - 1) * each, move = 'cut', filter = p.filter,
                        shot = { kind = 'fixed', pos = p.pos, rot = p.rot, fov = p.fov } }
        end
        return { keys = keys, length = #points * each, loop = opts.loop == true }
    end
    -- Times by distance, so the camera keeps one speed along the path.
    local total, at = 0.0, { 0.0 }
    for i = 2, #points do
        local a, b = points[i - 1].pos, points[i].pos
        if type(a) ~= 'table' and type(a) ~= 'vector3' or type(b) ~= 'table' and type(b) ~= 'vector3' then
            return nil, ('point %d needs a pos'):format(i)
        end
        local dx, dy, dz = (b.x or 0) - (a.x or 0), (b.y or 0) - (a.y or 0), (b.z or 0) - (a.z or 0)
        total = total + math.max(math.sqrt(dx * dx + dy * dy + dz * dz), 0.01)
        at[i] = total
    end
    local duration = tonumber(opts.duration or 10000) or 10000
    for i, p in ipairs(points) do
        keys[i] = { t = math.floor(duration * at[i] / total + 0.5), move = 'glide', ease = 'linear', filter = p.filter,
                    shot = { kind = 'fixed', pos = p.pos, rot = p.rot, fov = p.fov } }
    end
    -- The old easing names.
    local ease = ({ ['ease-in'] = 'in', ['ease-out'] = 'out' })[opts.easing] or opts.easing or 'smooth'
    return { keys = keys, length = duration, ease = ease, loop = opts.loop == true }
end
