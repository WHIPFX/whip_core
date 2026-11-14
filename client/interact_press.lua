-- ============================================
-- INTERACT PRESS — the hand goes out towards what the player uses
-- ============================================
--
-- A prompt marked `press` (AddAction's `press`, client/actions.lua; car doors, boot and bonnet,
-- client/vehicle_prompts.lua; a whip_core prompt registered with `press`, the ATM, client/interact.lua; whip_fuel's
-- pumps) plays a hand press as it is used: from WHERE THE PLAYER STANDS, the press whose hand points most nearly at
-- the prompt. Other resources: AddAction's `press`, or exports.whip_core:PlayPress(target, opts).
--
-- The press dictionaries (the standing set, its grip copy and the two arm sets) stay loaded once used, on purpose: a
-- press can come with any E, and one that streams in later misses its half second (no press that time).
--
-- JOSH'S RULES (2 Nov): the interaction happens INSTANTLY on E and the hand comes AFTER it, only how it looks; the
-- hand goes out and, the moment it reaches the point, comes straight back (no pause). It never walks, slides or
-- turns the player and never takes control from them; it does not have to reach the point, only try its best in
-- its general direction; and it must never bend the body unnaturally ("stop where it would make the character model
-- break"). So: InteractPress.play starts the press and answers at once (the caller has already done, or does now,
-- the thing); 3D Clanker's prebuilt poses, the STANDING ones only (Josh, 2 Nov: no knee bends; a low target gets the
-- standing low lean, "if it doesn't reach, it doesn't reach, and that's okay"), upper body with the player keeping
-- control. Ground pick ups are not presses: they play Rockstar's grab (client/ground.lua).
--
-- NO PAUSE: at the touch the clip skips its hold (the palm is still through it, so the jump is seamless) into its
-- own way back.
--
-- STOPPED AT THE SURFACE (Josh: yes, 2 Nov; Clanker's reach paths): a press reaches its full 0.25-0.75 m whatever is
-- in front, so a wall, door or car right there would take the hand through it. Each clip's reach_path (the palm
-- every frame to the touch) says where the palm meets the prompt's surface (it passes the surface's plane; with no
-- normal, it stops getting nearer): there the hand comes straight back (StopAnimTask 2.0). Already against it (frame
-- 2 or less): no press.
--
-- THE HAND FOLLOWS (Josh: yes, 2 Nov): while the hand is out, the game's arm IK keeps pulling it towards the point,
-- so running past a button the arm keeps reaching for it, only while the point stays within FOLLOW_CONE of the way
-- the clip reaches (and within maxDistance). Past that it lets go and the clip plays as made: never a twisted arm.
-- The RIGHT arm only: the left arm's IK (index 3) moved both arms in Josh's /reachik, which would fold the right arm
-- into the body on a left press (his note, 3 Nov; 3D Clanker).
--
-- THE CLIPS are Clanker's press set (whip@interact@press, standing only: high / upper / mid / chest / waist / low,
-- both arms at six headings each: the right at -40 (rx040, across), 0, 40, 90, 135, 175; the left at +40 (lx040,
-- across), 0, -40, -90, -135, -175; every left clip the right one's mirror image). data/interact_press.json lists
-- where each one's palm goes:
--
--   { "dict": "whip@interact@press", "ground_z": -1.0044, "fps": 30,
--     "clips": [ { "clip": "mid_r000", "arm": "right", "heading_deg": 0, "pitch_deg": 0,
--                  "contact_ms": 433, "hold_end_ms": 567, "duration_ms": 933, "needs_full_body": false,
--                  "contact": [x, y, z], "contact_f": [x, y, z], "push_dir": [x, y, z], "shoulder": [x, y, z],
--                  "effort": 0.2, "reach_path": [[x, y, z], ...] }, ... ] }
--
--   contact    the palm's centre at contact_ms, metres, in the ped's frame (+x right, +y forward) from
--              GetEntityCoords; contact_f the same on the female freemode ped (her skeleton matches: the same)
--   push_dir   the way the palm pushes, a unit vector in the same frame
--   shoulder   the reaching shoulder at contact, in the same frame
--   effort     how awkward the reach looks (0 .. about 1)
--   reach_path the palm every frame (header `fps`, 30) from frame 0 to the touch, in the same frame
--
-- Without that file, or without the dictionary streamed, there are no presses: InteractPress.play answers false,
-- 'off', and nothing plays. Read the arm from `arm`, never from the heading's sign (0 and 175 are both arms').
--
-- PICKING (3D Clanker's rules, 3 Nov, for Josh's notes: the other hand should take what the nearer one can't reach,
-- and the arm that looks better should win): every clip of every arm the set allows is a candidate, at the player's
-- own position and heading.
--   1. Where its palm stops on the way out: the stop rule below (stopOnPath).
--   2. A palm that would move less than MIN_TRAVEL before it stops is no candidate (the prompt is already at that
--      hand, or the surface is in its way at once): the next one gets its turn, often the other arm reaching across.
--   3. Its aim: the angle at the clip's OWN shoulder between where the palm stops and the prompt (measured from the
--      ped's middle, a point just left of it picked the right arm reaching inwards).
--   4. Its score: that angle in degrees, plus EFFORT_DEG for each unit of its effort, plus up to FACE_DEG for a palm
--      side-on to the surface. The lowest wins, whichever arm: no nearest arm first.
--   5. The winner aims more than MAX_ERR off (MAX_ERR_ARM for the arm-only sets, whose still torso can't help): no
--      press, the thing just happens. (With a two-handed gun, the left arm alone: something far round to the right,
--      or right behind, gets none, rather than a hand drifting towards it.)
--
-- AIMING (Josh): free aim, aiming from cover, or the aim control held with a weapon out: no press (and no ground grab,
-- client/ground.lua), the thing just happens.
--
-- Headings are GTA's: degrees, counter-clockwise from north. A ped at heading h faces (-sin h, cos h); its right
-- is (cos h, sin h).

-- ARMED OR IN COVER (Josh, 2 Nov; 3D Clanker's three more sets): the standing press carries the spine, both arms and
-- every finger, so over a gun or a cover pose it straightened the back and opened the gun hand. Clips that leave
-- those bones out keep whatever the player is already doing with them (RAGE layers an upper-body secondary clip only
-- on the bones it has: how Rockstar's own weapon and cover layers work).
--
--   standing, unarmed           the press (as above)
--   standing, one-handed gun    press_grip: the same clips, the right hand's fingers left out (it keeps its grip)
--   standing, two-handed gun    press_arm, the LEFT arm only (the right holds the gun where it is)
--   cover, unarmed              press_arm, the arm on the prompt's side
--   cover, one-handed gun       press_arm (left) or press_arm_grip (right, its fingers left out)
--   cover, two-handed gun       press_arm, the LEFT arm only
--
-- press_arm is the reaching arm alone (clavicle to fingers) from a still torso, its numbers in the CHEST's frame
-- (SKEL_Spine3, data/interact_press_arm.json: contact_s3, shoulder_s3, push_dir_s3, reach_path_s3, effort), so it
-- reaches the same whatever the cover pose does to the body. It is picked in that frame by the same rules (PICKING),
-- from both arms (a two-handed gun: the left only). In cover it starts at frame 2, so the arm doesn't dip towards
-- hanging first. One-handed: the pistols, the stun gun and melee; any other weapon is two.
-- A state whose set is not installed plays no press (the old full one broke cover and grips).

InteractPress = {}

local CORE      = GetCurrentResourceName()
local DATA_FILE = 'data/interact_press.json'
local ARM_FILE  = 'data/interact_press_arm.json'
local GRIP_DICT = 'whip@interact@press_grip'   -- the standing set without the right hand's fingers: same clips, same list
local CHEST     = 24818                        -- SKEL_Spine3: the arm sets' frame
local ONE_HANDED = { [416676503] = true, [690389602] = true, [2685387236] = true }   -- pistols, stun gun, melee

-- The pick (PICKING at the top; 3D Clanker's numbers): the least a palm moves to be a candidate (m); degrees of aim one
-- unit of effort is worth, and a palm side-on to the surface; the most the winner may aim off (degrees), standing and
-- with the arm-only sets.
local MIN_TRAVEL = 0.15
local EFFORT_DEG, FACE_DEG = 25.0, 10.0
local MAX_ERR, MAX_ERR_ARM = 35.0, 25.0
local BOTH_ARMS, LEFT_ARM = { left = true, right = true }, { left = true }

-- SET_IK_TARGET (citizenfx/natives PED/SetIkTarget.md): eIkPart 3 is the left arm and 4 the right; the bone to aim
-- at is -1 for none (0 is SKEL_ROOT); the target lasts one update, so it is set every frame. Josh watched /reachik on
-- 2 Nov: 4 moved the right (nearer) arm, 3 pulled the left one across, and the arm followed the point as he moved.
-- Used only to let the hand follow (Config.InteractPress.followHand), within FOLLOW_CONE.
local IK_ARM   = { left = 3, right = 4 }
local IK_NONE  = -1
local IK_FLAGS = 0
local FOLLOW_CONE = math.rad(60)   -- the point this far round from the way the clip reaches: the IK lets go


local function setIk(ped, arm, T)
    SetIkTarget(ped, IK_ARM[arm], 0, IK_NONE, T.x, T.y, T.z, IK_FLAGS, 100, 100)
end

local set = nil      -- the list, read once; false once found missing or unreadable
local busy = false   -- a press is going out (to the touch)
local busyBy = nil   -- which press set it (InteractPress.play): only that press clears it

-- ============================================
-- The list
-- ============================================

local function vec(t)
    if type(t) ~= 'table' and type(t) ~= 'vector3' then return nil end
    local x, y, z = tonumber(t.x or t[1]), tonumber(t.y or t[2]), tonumber(t.z or t[3])
    if not (x and y and z) then return nil end
    return { x, y, z }
end

local function loadSet()
    if set ~= nil then return set or nil end
    set = false
    local raw = LoadResourceFile(CORE, DATA_FILE)
    if not raw or raw == '' then return nil end   -- not installed: no presses
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' or type(data.dict) ~= 'string' or type(data.clips) ~= 'table' then
        print(('[whip_core:press] %s could not be read: no presses'):format(DATA_FILE))
        return nil
    end
    local clips = {}
    for i, c in ipairs(data.clips) do
        local contact = type(c) == 'table' and vec(c.contact)
        local contactMs, durationMs = type(c) == 'table' and tonumber(c.contact_ms), type(c) == 'table' and tonumber(c.duration_ms)
        if type(c) == 'table' and c.needs_full_body == true then
            -- A kneeling press: never used (Josh, 2 Nov: no knee bends in a press).
        elseif contact and contactMs and durationMs and type(c.clip) == 'string' then
            -- The palm's path to the touch, when the list has it (where the hand meets a surface first).
            local path = nil
            if type(c.reach_path) == 'table' and #c.reach_path > 2 then
                path = {}
                for _, p in ipairs(c.reach_path) do
                    local v = vec(p)
                    if not v then path = nil break end
                    path[#path + 1] = v
                end
            end
            clips[#clips + 1] = {
                clip       = c.clip,
                arm        = c.arm == 'left' and 'left' or 'right',
                round      = math.atan(contact[1], contact[2]),   -- which way round it reaches (+ right)
                path       = path,
                contact    = contact,
                shoulder   = vec(c.shoulder),
                effort     = tonumber(c.effort) or 0.0,
                push       = vec(c.push_dir),
                contactMs  = contactMs,
                holdEndMs  = tonumber(c.hold_end_ms) or contactMs,
                durationMs = durationMs,
            }
        else
            print(('[whip_core:press] %s: clip %d has no clip, contact, contact_ms or duration_ms: left out'):format(DATA_FILE, i))
        end
    end
    if #clips == 0 then
        print(('[whip_core:press] %s lists no usable clip: no presses'):format(DATA_FILE))
        return nil
    end
    set = { dict = data.dict, groundZ = tonumber(data.ground_z) or -1.0, fps = tonumber(data.fps) or 30, clips = clips }
    return set
end

--- Can presses play here: switched on, listed, and the dictionary streamed?
---@return boolean
function InteractPress.available()
    if not (Config.InteractPress and Config.InteractPress.enabled) then return false end
    local s = loadSet()
    return s ~= nil and DoesAnimDictExist(s.dict)
end

local armSet = nil   -- the arm sets' list, read once; false once found missing or unreadable

--- press_arm's list (data/interact_press_arm.json), its numbers in the chest's frame.
local function loadArm()
    if armSet ~= nil then return armSet or nil end
    armSet = false
    local raw = LoadResourceFile(CORE, ARM_FILE)
    if not raw or raw == '' then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' or type(data.clips) ~= 'table' or type(data.dicts) ~= 'table'
        or type(data.dicts.arm) ~= 'string' then
        print(('[whip_core:press] %s could not be read: no presses armed or in cover'):format(ARM_FILE))
        return nil
    end
    local clips, shoulder = {}, {}
    for _, c in ipairs(data.clips) do
        local contact, sh = type(c) == 'table' and vec(c.contact_s3), type(c) == 'table' and vec(c.shoulder_s3)
        local contactMs, durationMs = tonumber(c.contact_ms), tonumber(c.duration_ms)
        if contact and sh and contactMs and durationMs and type(c.clip) == 'string' then
            local path = nil
            if type(c.reach_path_s3) == 'table' and #c.reach_path_s3 > 2 then
                path = {}
                for _, p in ipairs(c.reach_path_s3) do
                    local v = vec(p)
                    if not v then path = nil break end
                    path[#path + 1] = v
                end
            end
            local arm = c.arm == 'left' and 'left' or 'right'
            shoulder[arm] = shoulder[arm] or sh
            clips[#clips + 1] = {
                clip = c.clip, arm = arm, contact = contact, shoulder = sh, push = vec(c.push_dir_s3), path = path,
                effort = tonumber(c.effort) or 0.0,
                contactMs = contactMs, holdEndMs = tonumber(c.hold_end_ms) or contactMs, durationMs = durationMs,
            }
        end
    end
    if #clips == 0 or not shoulder.left or not shoulder.right then
        print(('[whip_core:press] %s lists no usable clips for both arms: no presses armed or in cover'):format(ARM_FILE))
        return nil
    end
    armSet = { dict = data.dicts.arm, gripDict = data.dicts.arm_grip, fps = tonumber(data.fps) or 30,
               clips = clips, shoulder = shoulder }
    return armSet
end

-- ============================================
-- Picking
-- ============================================

local function unit(x, y, z)
    local len = math.sqrt(x * x + y * y + z * z)
    if len < 1e-6 then return 0.0, 0.0, 0.0 end
    return x / len, y / len, z / len
end

--- Where the palm stops on its way out (Clanker's stop rule): the point and its frame (from 0, between frames where it
--- crosses). With a normal `n` (facing the player): where it first passes the surface's plane through `t` — at once
--- when the resting hand is already on or past it (standing flush against it: that hand has nowhere to go); never
--- passing it, or with no normal: where it comes nearest `t`. `t` and `n` are in the path's own frame.
local function stopOnPath(path, t, n)
    if n then
        local p = path[1]
        local prev = (p[1] - t[1]) * n[1] + (p[2] - t[2]) * n[2] + (p[3] - t[3]) * n[3]
        if prev <= 0.0 then return p, 0 end
        for i = 2, #path do
            local q = path[i]
            local side = (q[1] - t[1]) * n[1] + (q[2] - t[2]) * n[2] + (q[3] - t[3]) * n[3]
            if side <= 0.0 then
                local f = prev / (prev - side)
                local a = path[i - 1]
                return { a[1] + (q[1] - a[1]) * f, a[2] + (q[2] - a[2]) * f, a[3] + (q[3] - a[3]) * f }, i - 2 + f
            end
            prev = side
        end
    end
    local best, bestD = 1, math.huge
    for i, q in ipairs(path) do
        local d = (q[1] - t[1]) ^ 2 + (q[2] - t[2]) ^ 2 + (q[3] - t[3]) ^ 2
        if d < bestD then best, bestD = i, d end
    end
    return path[best], best - 1
end

--- The angle between two vectors, in degrees (180 when either is nothing).
local function degBetween(ax, ay, az, bx, by, bz)
    local la, lb = math.sqrt(ax * ax + ay * ay + az * az), math.sqrt(bx * bx + by * by + bz * bz)
    if la < 1e-6 or lb < 1e-6 then return 180.0 end
    return math.deg(math.acos(math.max(-1.0, math.min(1.0, (ax * bx + ay * by + az * bz) / (la * lb)))))
end

--- The best clip for the prompt `t` (in the clips' own frame; `n` its normal there, facing the player, or nil) from
--- the arms `arms` allows, by PICKING's rules: the clip and the frame its palm stops at (nil: it plays to the touch),
--- or nil when none aims within `maxErr` degrees. `atEnd`: each clip is judged where its path ends instead of where
--- it would stop (a grab always plays on to its grab, so a palm only passing near the item on its way is no help).
local function choose(clips, t, n, arms, maxErr, atEnd)
    local best, bestScore, bestErr, bestK = nil, math.huge, nil, nil
    for _, c in ipairs(clips) do
        if arms[c.arm] and c.path and c.shoulder then
            local s, k
            if atEnd then s, k = c.path[#c.path], #c.path - 1 else s, k = stopOnPath(c.path, t, n) end
            local p0 = c.path[1]
            if (s[1] - p0[1]) ^ 2 + (s[2] - p0[2]) ^ 2 + (s[3] - p0[3]) ^ 2 >= MIN_TRAVEL * MIN_TRAVEL then
                local sh = c.shoulder
                local err = degBetween(s[1] - sh[1], s[2] - sh[2], s[3] - sh[3], t[1] - sh[1], t[2] - sh[2], t[3] - sh[3])
                local face = 1.0
                if n and c.push then face = math.max(0.0, -(c.push[1] * n[1] + c.push[2] * n[2] + c.push[3] * n[3])) end
                local score = err + EFFORT_DEG * c.effort + FACE_DEG * (1.0 - face)
                if score < bestScore then best, bestScore, bestErr, bestK = c, score, err, k end
            end
        end
    end
    if not best or bestErr > maxErr then return nil end
    -- Stopping at its last frame is the touch itself: it plays to it, and skips its hold
    if bestK >= #best.path - 1 - 1e-6 then bestK = nil end
    return best, bestK
end

--- The same pick for any clip set built like these (rows with arm, path, shoulder, effort, and push for a normal):
--- the low-cover ground grabs use it (client/ground.lua).
InteractPress.choose = choose

-- ============================================
-- The press
-- ============================================


--- Where a press target is now: a point, or { entity, offset?, bone? }.
local function targetPoint(target)
    if type(target) == 'vector3' or type(target) == 'vector4' then return vector3(target.x, target.y, target.z) end
    if type(target) ~= 'table' then return nil end
    local ent = target.entity
    if ent then
        if not DoesEntityExist(ent) then return nil end
        if target.bone then
            local idx = GetEntityBoneIndexByName(ent, tostring(target.bone))
            if idx ~= -1 then return GetWorldPositionOfEntityBone(ent, idx) end
        end
        local o = vec(target.offset) or { 0.0, 0.0, 0.0 }
        return GetOffsetFromEntityInWorldCoords(ent, o[1] + 0.0, o[2] + 0.0, o[3] + 0.0)
    end
    local p = vec(target)
    return p and vector3(p[1], p[2], p[3]) or nil
end

--- A world point (and direction) in the frame of a ped at P facing h: +x right, +y forward, z up.
local function toPed(P, h, x, y, z, isDir)
    local r = math.rad(h)
    local c, s = math.cos(r), math.sin(r)
    if not isDir then x, y, z = x - P.x, y - P.y, z - P.z end
    return x * c + y * s, -x * s + y * c, z
end

--- The chest's frame now: its origin and its three axes in the world (SKEL_Spine3's own, by GetPedBoneCoords offsets).
local function chestFrame(ped)
    local O = GetPedBoneCoords(ped, CHEST, 0.0, 0.0, 0.0)
    return O, GetPedBoneCoords(ped, CHEST, 1.0, 0.0, 0.0) - O, GetPedBoneCoords(ped, CHEST, 0.0, 1.0, 0.0) - O,
        GetPedBoneCoords(ped, CHEST, 0.0, 0.0, 1.0) - O
end

local function dot3(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

--- May the hand follow the point now: still within FOLLOW_CONE of `round` (the way the clip reaches, round the ped),
--- and within reach?
local function mayFollow(ped, round, T)
    local P = GetEntityCoords(ped)
    if #(T - P) > (Config.InteractPress.maxDistance or 2.5) then return false end
    local lx, ly = toPed(P, GetEntityHeading(ped), T.x, T.y, T.z)
    local d = (math.atan(lx, ly) - round + math.pi) % (2.0 * math.pi) - math.pi
    return math.abs(d) <= FOLLOW_CONE
end

--- One press, in its own thread: the dictionary (half a second at most, else no press this time), the clip going out
--- with the hand following the point, and at the touch (or where the palm meets the surface) straight back.
---@param p table  { dict, clip, fps, k (the stop frame or nil), startFrame (0, or 2 in cover), round }
---@param touched function|nil  called as the hand gets there (play calls it again, harmlessly, on the way out)
local function run(ped, p, T, touched)
    local dict, clip = p.dict, p.clip
    if not LoadAnimDict(dict, 500) then return end
    -- 48: upper body (16), the player keeps control (32).
    TaskPlayAnim(ped, dict, clip.clip, 8.0, 8.0, clip.durationMs, 48, 0.0, false, false, false)
    -- In cover, from frame 2: the arm starts where it is, not dipping towards hanging first.
    local startMs = 0
    if p.startFrame > 0 then
        startMs = math.floor(p.startFrame * 1000 / p.fps)
        SetEntityAnimCurrentTime(ped, dict, clip.clip, startMs / clip.durationMs)
    end
    local t0 = GetGameTimer()
    local touchMs = (p.k and math.floor(p.k * 1000 / p.fps) or clip.contactMs) - startMs
    -- Only the standing sets' right arm follows: in cover or with a gun (the arm sets) the IK moved both arms (Josh,
    -- 2 Nov), and the left arm's moved both too (THE HAND FOLLOWS).
    local follow = p.follow and Config.InteractPress.followHand ~= false
    local playing = function() return IsEntityPlayingAnim(ped, dict, clip.clip, 3) end

    -- Going out: the hand follows the point (within FOLLOW_CONE).
    Wait(0)
    while GetGameTimer() - t0 < touchMs do
        if not playing() then return end
        if follow and mayFollow(ped, p.round, T) then setIk(ped, clip.arm, T) end
        Wait(0)
    end
    if busyBy == p.mine then busy = false end   -- the hand is there: the next press may go (this press's flag only)
    if touched then touched() end               -- (its own thread: the hand never waits on it)
    if not playing() then return end

    if p.k then
        -- Met the surface on the way: straight back from there (Clanker's 2.0 blend).
        StopAnimTask(ped, dict, clip.clip, 2.0)
        return
    end
    -- Touched: no pause. The palm holds still through the hold, so the clip jumps from the touch to the hold's end
    -- without a seam, into its own way back.
    SetEntityAnimCurrentTime(ped, dict, clip.clip, clip.holdEndMs / clip.durationMs)
end

--- What the player holds: 0 (nothing), 1 (a one-handed weapon: the pistols, the stun gun, melee), or 2.
local function handsOf(ped)
    local w = GetSelectedPedWeapon(ped)
    if w == 0 or w == `WEAPON_UNARMED` then return 0 end
    return ONE_HANDED[GetWeapontypeGroup(w) & 0xFFFFFFFF] and 1 or 2
end
InteractPress.hands = handsOf

--- Is the player aiming: free aim, aiming from cover, or the aim control held with a weapon out? Then no press or
--- ground grab plays, the thing just happens (Josh: "things will just magically activate without the animations").
---@param ped number
---@return boolean
function InteractPress.aiming(ped)
    return IsPlayerFreeAiming(PlayerId()) or IsPedAimingFromCover(ped)
        or (handsOf(ped) > 0 and IsControlPressed(0, 25))
end

--- The hand goes out towards a point from where the player stands, and comes straight back as it gets there. It
--- answers AT ONCE (the press plays in its own thread): the interaction is the caller's, done before or right after
--- this, never waiting on it. Safe inside a prompt's callback (it never waits). It never moves or turns the player.
---
---   target  a point (vector3), or { entity, offset?, bone? } (offset in the entity's frame)
---   opts    normal = the way the surface faces (a vector3, either way round): a press pushing into it is preferred,
---           and the hand comes back where it meets that surface
---           onContact = function() run as the hand gets there (under pcall)
---
--- onContact runs EXACTLY ONCE for a press that went out (true): as the hand gets there, or, should the press be cut
--- short (the clip lost to a ragdoll, a car, an emote; its dictionary slow to stream), as it ends. Never for false:
--- then the caller just does the thing.
---
--- true: a press is going out. false, why: 'off' (none: presses off or not installed, no target, too far, the
--- player seated, falling or aiming, no clip aims near enough or every palm would barely move), 'busy' (one is going
--- out), 'dead'.
---@param target vector3|table
---@param opts table|nil
---@return boolean started
---@return string|nil why
function InteractPress.play(target, opts)
    opts = opts or {}
    if not InteractPress.available() then return false, 'off' end
    if busy then return false, 'busy' end
    local T = targetPoint(target)
    if not T then return false, 'off' end

    local ped = PlayerPedId()
    if PlayerIsDead or IsEntityDead(ped) then return false, 'dead' end
    -- Seated, falling, ragdolled, swimming: no press, the thing just happens.
    if IsPedInAnyVehicle(ped, true) or IsPedRagdoll(ped) or IsPedFalling(ped) or IsPedSwimming(ped)
        or InteractPress.aiming(ped) then
        return false, 'off'
    end
    local P = GetEntityCoords(ped)
    if #(T - P) > (Config.InteractPress.maxDistance or 2.5) then return false, 'off' end

    -- The normal, facing the player whichever way round it was given.
    local N = nil
    local given = opts.normal and vec(opts.normal)
    if given then
        local x, y, z = unit(given[1], given[2], given[3])
        if x ~= 0.0 or y ~= 0.0 or z ~= 0.0 then
            if x * (P.x - T.x) + y * (P.y - T.y) + z * (P.z - T.z) < 0 then x, y, z = -x, -y, -z end
            N = { x = x, y = y, z = z }
        end
    end

    -- Which set (see ARMED OR IN COVER at the top), its clip, and where the hand meets the surface on the way (nil: it
    -- never does before the touch). None aims near enough, or every palm would barely move: no press (PICKING).
    local hands, cover = handsOf(ped), IsPedInCover(ped, false)
    local h = GetEntityHeading(ped)
    local p
    if not cover and hands < 2 then
        local s = set --[[@as table]]   -- loaded: InteractPress.available() above
        -- The prompt in the ped's frame (the list's)
        local t = { toPed(P, h, T.x, T.y, T.z) }
        local n = N and { toPed(P, h, N.x, N.y, N.z, true) } or nil
        local clip, k = choose(s.clips, t, n, BOTH_ARMS, MAX_ERR)
        if not clip then return false, 'off' end
        local dict = s.dict
        if hands == 1 then
            if not DoesAnimDictExist(GRIP_DICT) then return false, 'off' end
            dict = GRIP_DICT
        end
        p = { dict = dict, clip = clip, fps = s.fps, k = k, startFrame = 0, round = clip.round,
              follow = clip.arm == 'right' }
    else
        local a = loadArm()
        if not a or not DoesAnimDictExist(a.dict) then return false, 'off' end
        local O, X, Y, Z = chestFrame(ped)
        local d = T - O
        local t = { dot3(d, X), dot3(d, Y), dot3(d, Z) }
        local n = N and { dot3(N, X), dot3(N, Y), dot3(N, Z) } or nil
        local clip, k = choose(a.clips, t, n, hands == 2 and LEFT_ARM or BOTH_ARMS, MAX_ERR_ARM)
        if not clip then return false, 'off' end
        local dict = a.dict
        if cover and hands == 1 and clip.arm == 'right' then
            if not a.gripDict or not DoesAnimDictExist(a.gripDict) then return false, 'off' end
            dict = a.gripDict
        end
        -- Which way round the ped its palm goes, for the hand following the point.
        local c = clip.contact
        local cw = O + X * c[1] + Y * c[2] + Z * c[3]
        local lx, ly = toPed(P, h, cw.x, cw.y, cw.z)
        p = { dict = dict, clip = clip, fps = a.fps, k = k, startFrame = cover and 2 or 0, round = math.atan(lx, ly),
              follow = false }
    end

    -- onContact once, whichever way the press ends (the action is never left waiting on it). In its own thread: one
    -- that waits held the hand in the touch, past the surface it should come back from (audit 20, INT-1).
    local touched = nil
    if opts.onContact then
        local done = false
        touched = function()
            if done then return end
            done = true
            CreateThread(function()
                local okc, err = pcall(opts.onContact)
                if not okc then print(('[whip_core:press] onContact failed: %s'):format(tostring(err))) end
            end)
        end
    end

    -- This press's own busy: a press ending late never clears the flag of the one after it
    local mine = {}
    p.mine = mine
    busy, busyBy = true, mine
    CreateThread(function()
        local ok, err = pcall(run, ped, p, T, touched)
        if busyBy == mine then busy, busyBy = false, nil end
        if not ok then print(('[whip_core:press] failed: %s'):format(tostring(err))) end
        if touched then touched() end
    end)
    return true
end

--- A whip_core prompt registered with `press` (client/interact.lua: the ATM): the press towards its circle, facing
--- the way the circle faces. After the option has run.
---@param data table  the prompt's registry record
function InteractPress.atPrompt(data)
    if not data or not data.x then return end
    local normal = nil
    if data.heading then
        local r = math.rad(data.heading)
        normal = vector3(-math.sin(r), math.cos(r), 0.0)
    end
    InteractPress.play(vector3(data.x, data.y, data.z), { normal = normal })
end

--- For other resources: the hand goes out towards a point (see InteractPress.play). Answers at once.
exports('PlayPress', function(target, opts)
    return InteractPress.play(target, opts)
end)
