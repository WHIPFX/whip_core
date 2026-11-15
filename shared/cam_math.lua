-- ============================================
-- CamMath — the camera system's maths
-- ============================================
--
-- No natives: everything here is arithmetic, so it is tested off the game (dev harness), and shared, so
-- the server checks sequences with it too. The camera system is three files: this one,
-- client/cam_shots.lua (where each kind of shot puts the camera) and shared/cam_sequence.lua (a timeline
-- of shots, and how the camera gets from one to the next).
--
-- WHERE IT COMES FROM. The box fit is whip_autos' showroom camera's; the curve through points is the old
-- Camera Creator's (client/camera.lua).
--
-- A ROTATION is GTA's camera rotation, order 2: pitch (x, up is positive), roll (y), yaw (z, heading,
-- counter-clockwise). As a matrix that is Rz(yaw) * Rx(pitch) * Ry(roll) on the axes right = +x,
-- forward = +y, up = +z: a camera at pitch p, yaw h looks along (-sin h cos p, cos h cos p, sin p).
-- Blending two rotations goes through quaternions (w, x, y, z as q[1..4]), so it never flips or wobbles
-- the way blending the three angles one by one does.

CamMath = {}

local abs, sqrt, sin, cos, asin, acos, exp = math.abs, math.sqrt, math.sin, math.cos, math.asin, math.acos, math.exp
local rad, deg, floor = math.rad, math.deg, math.floor
local atan2 = math.atan   -- Lua 5.4: math.atan(y, x) is atan2

-- ============================================
-- Numbers and angles
-- ============================================

---@param v number
---@param lo number
---@param hi number
---@return number
function CamMath.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
local clamp = CamMath.clamp

function CamMath.lerp(a, b, t) return a + (b - a) * t end
local lerp = CamMath.lerp

--- An angle in (-180, 180].
---@param a number
---@return number
function CamMath.wrap180(a) return (a + 180.0) % 360.0 - 180.0 end
local wrap180 = CamMath.wrap180

--- b, give or take whole turns, as close to a as it can be: the way to turn from a to b without going the
--- long way round.
---@param a number
---@param b number
---@return number
function CamMath.nearestAngle(a, b)
    return a + wrap180(b - a)
end
local nearestAngle = CamMath.nearestAngle

--- From a towards b by t, the short way round. Answers in (-180, 180].
function CamMath.lerpAngle(a, b, t)
    return wrap180(lerp(a, nearestAngle(a, wrap180(b)), t))
end

--- Towards a target at `rate`, the same at any frame rate: what the camera's springs are made of. A higher
--- rate is a tighter spring (about 63% of the way in 1/rate seconds).
---@param current number
---@param target number
---@param rate number
---@param dt number  seconds
---@return number
function CamMath.damp(current, target, rate, dt)
    return target + (current - target) * exp(-rate * dt)
end

--- The same for an angle, the short way round. Answers in (-180, 180].
function CamMath.dampAngle(current, target, rate, dt)
    local t = nearestAngle(current, wrap180(target))
    return wrap180(t + (current - t) * exp(-rate * dt))
end

-- ============================================
-- How a move speeds up and slows down
-- ============================================
--
-- u (0..1, the share of the move's time gone) to how far along it is. `smooth` starts and ends gently,
-- `in` starts gently, `out` ends gently, `strong` is smooth with longer ends, `linear` is steady.

local EASES = {
    linear = function(u) return u end,
    smooth = function(u) return u * u * (3.0 - 2.0 * u) end,
    ['in'] = function(u) return u * u * u end,
    out    = function(u) local v = 1.0 - u; return 1.0 - v * v * v end,
    strong = function(u) return u * u * u * (u * (u * 6.0 - 15.0) + 10.0) end,
}
CamMath.EASE_NAMES = { 'linear', 'smooth', 'in', 'out', 'strong' }

---@param name string|nil
---@return boolean
function CamMath.isEase(name) return EASES[name] ~= nil end

---@param name string|nil  one of CamMath.EASE_NAMES; anything else is linear
---@param u number
---@return number
function CamMath.ease(name, u)
    u = clamp(u, 0.0, 1.0)
    local f = EASES[name] or EASES.linear
    return f(u)
end

--- A spring's way of arriving, made to arrive: quick at first, settling into the end, and exactly there
--- at u = 1. `rate` is how quick (about 3 gentle, 8 brisk).
function CamMath.springEase(u, rate)
    u = clamp(u, 0.0, 1.0)
    rate = math.max(tonumber(rate) or 4.0, 0.1)
    return (1.0 - exp(-rate * u)) / (1.0 - exp(-rate))
end

-- ============================================
-- Directions and places
-- ============================================

--- Which way a camera at pitch, yaw (degrees) looks.
---@return number x, number y, number z
function CamMath.forward(pitch, yaw)
    local p, h = rad(pitch), rad(yaw)
    local cp = cos(p)
    return -sin(h) * cp, cos(h) * cp, sin(p)
end

--- The pitch and yaw that look along a direction.
---@return number pitch, number yaw
function CamMath.rotFromDir(dx, dy, dz)
    local l = sqrt(dx * dx + dy * dy + dz * dz)
    if l < 1e-6 then return 0.0, 0.0 end
    return deg(asin(clamp(dz / l, -1.0, 1.0))), deg(atan2(-dx / l, dy / l))
end

--- A place offset from (px, py, pz) by (right, forward, up) metres, turned to `heading`.
---@return number x, number y, number z
function CamMath.localToWorld(px, py, pz, heading, right, fwd, up)
    local h = rad(heading)
    local fx, fy = -sin(h), cos(h)
    local rx, ry = cos(h), sin(h)
    return px + rx * right + fx * fwd, py + ry * right + fy * fwd, pz + up
end

--- The other way: a world place as (right, forward, up) from (px, py, pz) turned to `heading`.
---@return number right, number fwd, number up
function CamMath.worldToLocal(px, py, pz, heading, wx, wy, wz)
    local h = rad(heading)
    local dx, dy = wx - px, wy - py
    return dx * cos(h) + dy * sin(h), -dx * sin(h) + dy * cos(h), wz - pz
end

-- ============================================
-- Rotations as quaternions
-- ============================================

--- q = qz(yaw) * qx(pitch) * qy(roll), from GTA's degrees.
---@return table q  { w, x, y, z }
function CamMath.quatFromEuler(pitch, roll, yaw)
    local hp, hr, hy = rad(pitch) * 0.5, rad(roll) * 0.5, rad(yaw) * 0.5
    local cp, sp, cr, sr, cy, sy = cos(hp), sin(hp), cos(hr), sin(hr), cos(hy), sin(hy)
    -- qx * qy first: (cp, sp, 0, 0) * (cr, 0, sr, 0)
    local w1, x1, y1, z1 = cp * cr, sp * cr, cp * sr, sp * sr
    -- then qz * that: (cy, 0, 0, sy) * (w1, x1, y1, z1)
    return { cy * w1 - sy * z1, cy * x1 - sy * y1, cy * y1 + sy * x1, cy * z1 + sy * w1 }
end

--- Back to GTA's degrees: pitch, roll, yaw.
---@param q table
---@return number pitch, number roll, number yaw
function CamMath.quatToEuler(q)
    local w, x, y, z = q[1], q[2], q[3], q[4]
    local r01 = 2.0 * (x * y - w * z)
    local r11 = 1.0 - 2.0 * (x * x + z * z)
    local r20 = 2.0 * (x * z - w * y)
    local r21 = 2.0 * (y * z + w * x)
    local r22 = 1.0 - 2.0 * (x * x + y * y)
    return deg(asin(clamp(r21, -1.0, 1.0))), deg(atan2(-r20, r22)), deg(atan2(-r01, r11))
end

local function qdot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4] end

local function qnorm(q)
    local l = sqrt(qdot(q, q))
    if l < 1e-9 then return { 1.0, 0.0, 0.0, 0.0 } end
    return { q[1] / l, q[2] / l, q[3] / l, q[4] / l }
end

local function qmul(a, b)
    return {
        a[1] * b[1] - a[2] * b[2] - a[3] * b[3] - a[4] * b[4],
        a[1] * b[2] + a[2] * b[1] + a[3] * b[4] - a[4] * b[3],
        a[1] * b[3] - a[2] * b[4] + a[3] * b[1] + a[4] * b[2],
        a[1] * b[4] + a[2] * b[3] - a[3] * b[2] + a[4] * b[1],
    }
end
CamMath.quatMul = qmul

local function qconj(q) return { q[1], -q[2], -q[3], -q[4] } end

--- The same rotation, on the same side as `ref` (q and -q are one rotation; blending must pick one).
local function qnear(ref, q)
    if qdot(ref, q) < 0.0 then return { -q[1], -q[2], -q[3], -q[4] } end
    return q
end

--- From a to b by t, at an even turning speed, the short way round.
function CamMath.quatSlerp(a, b, t)
    b = qnear(a, b)
    local d = clamp(qdot(a, b), -1.0, 1.0)
    if d > 0.9995 then
        return qnorm({ lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t), lerp(a[4], b[4], t) })
    end
    local th = acos(d)
    local s = sin(th)
    local wa, wb = sin((1.0 - t) * th) / s, sin(t * th) / s
    return { a[1] * wa + b[1] * wb, a[2] * wa + b[2] * wb, a[3] * wa + b[3] * wb, a[4] * wa + b[4] * wb }
end
local slerp = CamMath.quatSlerp

local function qlog(q)
    local v = sqrt(q[2] * q[2] + q[3] * q[3] + q[4] * q[4])
    if v < 1e-9 then return { 0.0, 0.0, 0.0, 0.0 } end
    local k = atan2(v, q[1]) / v
    return { 0.0, q[2] * k, q[3] * k, q[4] * k }
end

local function qexp(q)
    local v = sqrt(q[2] * q[2] + q[3] * q[3] + q[4] * q[4])
    if v < 1e-9 then return { 1.0, 0.0, 0.0, 0.0 } end
    local s = sin(v) / v
    return { cos(v), q[2] * s, q[3] * s, q[4] * s }
end

--- The inner handle of q1 between q0 and q2, for quatSquad.
local function squadHandle(q0, q1, q2)
    local inv = qconj(q1)
    local a, b = qlog(qmul(inv, q2)), qlog(qmul(inv, q0))
    return qmul(q1, qexp({ 0.0, -(a[2] + b[2]) * 0.25, -(a[3] + b[3]) * 0.25, -(a[4] + b[4]) * 0.25 }))
end

--- Through q1 and q2 by t, curving with the rotations either side (q0 before, q3 after) so a turn that
--- goes on through a point does not kink there. All four on one side first.
function CamMath.quatSquad(q0, q1, q2, q3, t)
    q0 = qnear(q1, q0)
    q2 = qnear(q1, q2)
    q3 = qnear(q2, q3)
    local s1, s2 = squadHandle(q0, q1, q2), squadHandle(q1, q2, q3)
    return slerp(slerp(q1, q2, t), slerp(s1, s2, t), 2.0 * t * (1.0 - t))
end

-- ============================================
-- Curves through points
-- ============================================

--- Centripetal Catmull-Rom (alpha 0.5) from p1 to p2 by t, curving with p0 and p3: no loops or cusps
--- however unevenly the points are spaced. Points have x, y, z. Answers x, y, z.
function CamMath.catmullRom(p0, p1, p2, p3, t)
    local function d(a, b)
        local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
        return math.max(sqrt(sqrt(dx * dx + dy * dy + dz * dz)), 0.0316)   -- distance ^ 0.5, never 0
    end
    local t0 = 0.0
    local t1 = t0 + d(p0, p1)
    local t2 = t1 + d(p1, p2)
    local t3 = t2 + d(p2, p3)
    local tt = t1 + t * (t2 - t1)
    local function lv(a, b, ta, tb)
        local f = (tt - ta) / (tb - ta)
        return { x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f, z = a.z + (b.z - a.z) * f }
    end
    local a1, a2, a3 = lv(p0, p1, t0, t1), lv(p1, p2, t1, t2), lv(p2, p3, t2, t3)
    local b1, b2 = lv(a1, a2, t0, t2), lv(a2, a3, t1, t3)
    local c = lv(b1, b2, t1, t2)
    return c.x, c.y, c.z
end
local catmullRom = CamMath.catmullRom

--- A number through v1 and v2 by t, curving with v0 and v3 (uniform Catmull-Rom): a lens that keeps
--- zooming through a point instead of stopping at it.
function CamMath.hermite(v0, v1, v2, v3, t)
    local m1, m2 = (v2 - v0) * 0.5, (v3 - v1) * 0.5
    local t2, t3 = t * t, t * t * t
    return (2 * t3 - 3 * t2 + 1) * v1 + (t3 - 2 * t2 + t) * m1 + (-2 * t3 + 3 * t2) * v2 + (t3 - t2) * m2
end

local ARC_STEPS = 16

--- A Catmull-Rom stretch measured along its length, so a move can go at an even speed along it (the
--- curve's own t runs faster on a long side than a short one). Answers a table for CamMath.arcParam.
function CamMath.arcTable(p0, p1, p2, p3)
    local lens = { 0.0 }
    local px, py, pz = p1.x, p1.y, p1.z
    local total = 0.0
    for i = 1, ARC_STEPS do
        local x, y, z = catmullRom(p0, p1, p2, p3, i / ARC_STEPS)
        local dx, dy, dz = x - px, y - py, z - pz
        total = total + sqrt(dx * dx + dy * dy + dz * dz)
        lens[i + 1] = total
        px, py, pz = x, y, z
    end
    return { lens = lens, total = total }
end

--- The curve's t at a share `u` of its length.
function CamMath.arcParam(tab, u)
    u = clamp(u, 0.0, 1.0)
    if tab.total < 1e-6 then return u end
    local want = u * tab.total
    local lens = tab.lens
    for i = 1, ARC_STEPS do
        if lens[i + 1] >= want then
            local span = lens[i + 1] - lens[i]
            local f = span > 1e-9 and (want - lens[i]) / span or 0.0
            return ((i - 1) + f) / ARC_STEPS
        end
    end
    return 1.0
end

-- ============================================
-- Shake
-- ============================================
--
-- Two sines a little out of tune on each axis, so it reads as a camera in hands (or on a car)
-- rather than one clean wobble. On the turn, not the place: shaking where the camera IS pushes it
-- through walls; shaking where it LOOKS reads the same on screen.

--- How far the shake turns the camera at `seconds`, for `mag` degrees at `freq` turns a second. The
--- same moment always shakes the same way, so a timeline scrubbed back and forth shakes alike.
---@return number dPitch, number dRoll, number dYaw
function CamMath.shake(seconds, mag, freq)
    if mag <= 0.0 then return 0.0, 0.0, 0.0 end
    local p = seconds * (freq or 7.0) * 6.28318
    return (sin(p) * 0.6 + sin(p * 2.37 + 1.1) * 0.4) * mag,
           (sin(p * 1.63 + 2.2) * 0.6 + sin(p * 3.11) * 0.4) * mag * 0.6,
           (sin(p * 0.87 + 4.0) * 0.6 + sin(p * 1.91 + 0.5) * 0.4) * mag * 0.4
end

-- ============================================
-- Framing a box
-- ============================================
--
-- whip_autos': one framing fits anything, a bike or a bus, a person or a crate. Distance is a multiple
-- of the distance at which the thing's box just fills the screen, and the point looked at is a share of
-- its box.

--- The camera's axes when it looks along (pitch, yaw).
---@return table right, table up, table fwd   each { x, y, z }
function CamMath.basis(pitch, yaw)
    local fx, fy, fz = CamMath.forward(pitch, yaw)
    -- right = forward x up(0,0,1), level
    local rx, ry = fy, -fx
    local rl = sqrt(rx * rx + ry * ry)
    if rl < 1e-6 then rx, ry, rl = 1.0, 0.0, 1.0 end
    rx, ry = rx / rl, ry / rl
    -- up = right x forward
    local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
    return { x = rx, y = ry, z = 0.0 }, { x = ux, y = uy, z = uz }, { x = fx, y = fy, z = fz }
end

--- The distance from the box's centre at which all its corners are on screen, looking along `fwd`.
---@param corners table  { { x, y, z }, ... } world corners
---@param cx number  the box's centre
---@param tanV number  tan of half the vertical field of view
---@param tanH number  tan of half the horizontal
---@return number
function CamMath.fitDistance(corners, cx, cy, cz, tanV, tanH, right, up, fwd)
    local d = 0.0
    for i = 1, #corners do
        local c = corners[i]
        local rx, ry, rz = c.x - cx, c.y - cy, c.z - cz
        local u = rx * right.x + ry * right.y + rz * right.z
        local v = rx * up.x + ry * up.y + rz * up.z
        local f = rx * fwd.x + ry * fwd.y + rz * fwd.z
        local needV = abs(v) / tanV - f
        local needH = abs(u) / tanH - f
        if needV > d then d = needV end
        if needH > d then d = needH end
    end
    return math.max(d, 0.5)
end

--- Tangents of half the view at a vertical FOV and a screen's width over height.
---@return number tanV, number tanH
function CamMath.tangents(fov, aspect)
    local tanV = math.tan(rad(fov * 0.5))
    return tanV, tanV * (aspect or (16.0 / 9.0))
end

--- Round to `places` decimals (for code and saved shots: what is shown is what is kept).
function CamMath.round(v, places)
    local m = 10 ^ (places or 3)
    return floor(v * m + 0.5) / m
end
