-- ============================================
-- NPCS — the NPC Creator (client): what the OWNING game does with an NPC's brain
-- ============================================
--
-- The server keeps every NPC's record and sends its BRAIN to whichever game owns the ped (see
-- server/npcs.lua for why it has to). This file is that owner's half:
--
--   * apply the brain once (group, combat and flee settings, invincibility, weapon, freezing, and one
--     task: fight a target, or go back to its post and stand / guard there), and say so
--   * while this game owns the ped, watch it every quarter second: report its death, pick a target
--     again when it is not fighting but should be (one who came into range, or got back up), walk
--     it home, and keep an NPC that stands inside an MLO frozen until THIS game has floor under it
--     (its interior loaded, or ground at its post; plus collision and two seconds), freezing it again
--     if the floor goes away (the Mirror Park loader unloads homes). Only while it is at its post: one
--     walking there, or led out of the house, is not held by an interior it is not in
--   * every game knows which NPCs stand inside an MLO (the server tells it), so the game that newly
--     owns one freezes it at once, before its brain has even arrived: a ped handed to a game without
--     the interior would otherwise fall through the house in the meantime
--
-- What it does when it is not fighting (the Director's NPC cards), in this order:
--   flee    run from that player (and fight nobody)
--   follow  walk after that player; with them gone, stand where it is
--   home    walk (or run: pace) back to its post when it is away from it: a moved post is how it is
--           sent somewhere
--   anim    play its animation (or scenario) there, or else stand / guard
--
-- No Wait(0): one watch loop for every NPC this game owns, at 250 ms, ending when it owns none,
-- and one gate thread while any MLO NPC exists (100 ms while one is near, one second otherwise).

local _, NPC_GROUP = AddRelationshipGroup('WHIP_NPC')
SetRelationshipBetweenGroups(3, NPC_GROUP, `PLAYER`)   -- 3 = neutral: NPCs start on nobody by themselves
SetRelationshipBetweenGroups(3, `PLAYER`, NPC_GROUP)

-- ONE OF WHIP'S NPCS FIGHTING ANOTHER (NPC Attacks at an NPC, Fight an NPC). GTA has no ped take on one of its own
-- group, and every whip NPC is in NPC_GROUP: told to fight one, it never got into combat at all. So on the game
-- running the fight, the NPC fought is held in FOE_GROUP while the fight is on (holdFoe, FOE_HOLD_MS after each
-- look), which whip's NPCs take as they take players: neutral, fought only when told to. Its owner's game gives it its
-- own group back once the hold has run out (the watch). Two foes are neutral to each other too: two NPCs set at each
-- other are both held.
local _, FOE_GROUP = AddRelationshipGroup('WHIP_NPC_FOE')
SetRelationshipBetweenGroups(3, NPC_GROUP, FOE_GROUP)
SetRelationshipBetweenGroups(3, FOE_GROUP, NPC_GROUP)
SetRelationshipBetweenGroups(3, FOE_GROUP, FOE_GROUP)
SetRelationshipBetweenGroups(3, FOE_GROUP, `PLAYER`)
SetRelationshipBetweenGroups(3, `PLAYER`, FOE_GROUP)
local FOE_HOLD_MS = 2000
local foeUntil = {}   -- [netId] = GetGameTimer() until which a fight on this game holds that NPC in FOE_GROUP

local SETTLE_MS    = 2000
local RETARGET_MS  = 2000    -- a ped not fighting but with targets looks again this often
local HOME_RANGE   = 2.0     -- further than this from its post, it walks back before standing / guarding
local HOME_GIVE_UP = 30000   -- a walk home that has not arrived by then (or twice as long as it should take) stops where it is
local FELL_BY      = 0.5     -- this far below its post and outside any interior: it fell through
local FELL_FLAT    = 3.0     -- ...and within this of it across: it fell straight down there
local GATE_NEAR    = 20.0    -- an MLO NPC further than this (flat) from its post is not in that MLO: the interior has no say
local PACE         = { walk = { blend = 1.0, mps = 1.2 }, run = { blend = 2.0, mps = 3.5 } }
local FLEE_FAR     = 150.0   -- how far it runs from whoever it flees

local watches = {}    -- [netId] = { id, netId, brain, gate, post, canMove, ready, settleAt, deadSent, retargetAt, homeBy }
local gates   = {}    -- [netId] = { id, at }: every NPC standing inside an MLO (from the server)
local gateThread = false

-- (A ped from its network id, whether this game runs it, a player's ped by server id: DirectorKit's, shared/director/kit.lua.)
local pedFor, mine, pedOfServerId = DirectorKit.entityOfNet, DirectorKit.mine, DirectorKit.pedOfServerId

local function nearestTarget(ped, targets)
    local best, bestD
    local here = GetEntityCoords(ped)
    for _, sid in ipairs(targets or {}) do
        local p = pedOfServerId(sid)
        if p then
            local d = #(GetEntityCoords(p) - here)
            if not bestD or d < bestD then best, bestD = p, d end
        end
    end
    return best
end

--- Is the MLO at `at` here and loaded? IS_INTERIOR_READY, as prop sets and property objects ask it:
--- an interior the game knows of is not yet one whose rooms and floor are in.
local function interiorAt(at)
    if at == nil then return false end
    local id = GetInteriorAtCoords(at.x, at.y, at.z + 1.0)
    return id ~= 0 and IsInteriorReady(id)
end

--- Is there floor under the spot, at its height? A post is where the ped stands: a metre or so above
--- the floor, never below it.
local FLOOR_ABOVE, FLOOR_BELOW = 2.0, 0.5
local function floorAt(at)
    if at == nil then return false end
    local found, z = GetGroundZFor_3dCoord(at.x, at.y, at.z + 1.0, false)
    if not found then return false end
    local d = at.z - z
    return d >= -FLOOR_BELOW and d <= FLOOR_ABOVE
end

--- May an MLO NPC at `at` stand there now? The hold is for not falling through a house whose interior
--- has not come in yet, so the question is FLOOR, not an interior: its MLO loaded, or ground right
--- under it (an NPC set "inside an interior" on a street must not wait for ever). An upstairs room of a
--- house not loaded still holds: the only ground there is the street far below.
local function standsAt(at)
    return interiorAt(at) or floorAt(at)
end

local function flatDistance(ped, at)
    local c = GetEntityCoords(ped)
    local dx, dy = c.x - at.x, c.y - at.y
    return math.sqrt(dx * dx + dy * dy)
end

--- Whether this NPC should be frozen right now (its tasks' Freeze holds it too, and a list that ended on one: the
--- brain's frozen). Never one riding in a car, nor one fixed to a car it stands on (onCar, below).
local function shouldFreeze(w)
    if w.onCar then return false end
    if w.brain and w.brain.ride and not w.brain.job then return false end
    return (not w.canMove) or (w.gate and not w.ready)
        or (w.brain and (w.brain.frozen == true or (w.brain.job and w.brain.job.frozen == true)))
end

--- The car an NPC rides in (its brain's ride), when this game has it.
local function rideCar(ride)
    return type(ride) == 'table' and DirectorKit.entityOfNet(ride.net, 2) or nil
end

--- Sat in its seat, and kept there (a take's driver or passenger): seated again if it is out of it.
local function seat(ped, ride)
    local car = rideCar(ride)
    if not car then return end
    if GetVehiclePedIsIn(ped, false) ~= car then SetPedIntoVehicle(ped, car, ride.seat) end
end

-- ---- on a car players can stand on ----
--
-- An NPC standing on a car the scenario lets players stand on while it moves (the car's page: VehicleData
-- directorStandOn, client/director_standon.lua) rides it. Its owner fixes it to the car where it stands, facing as it
-- does (attached, as a mission's gunmen on a truck bed), so the car carries it, GTA's fall-off never throws it, and
-- its freeze, its post and its walk home (all a spot in the world, where the car no longer is) leave it alone. It
-- still looks, aims, shoots, plays its emote and fights from there, turned by its hold to what it aims at (GTA cannot
-- turn a ped fixed to a car: only its head and arms follow). A task that takes it somewhere (a step that moves), sitting in a car,
-- running away, following someone, or its death lets go of it first; standing on the car again after, it is fixed
-- again. Looked at by the watch every quarter second and as a brain is applied; only with such a car near.

local ONCAR_KEY   = 'directorStandOn'
local ONCAR_NEAR  = 15.0     -- a car whose middle is further than this cannot be the one under it
local ONCAR_PROBE = 3.0      -- how far under it a car is looked for (one held a little above the bed still counts)
local function moves(s) return DirectorSteps.is(s.t, 'moves') end

--- Such cars in this game, [entity] = true: kept by whip's vehicle data watcher (client/vehicle_data.lua) as their data
--- comes and goes, so the watch never looks through the world's cars (with traffic about, that read every car's whole
--- data block: some 36 KB a second while driving past an NPC this game owns). Usually none.
local standOnCars = {}
CreateThread(function()   -- once every file has loaded: VehicleData is client/vehicle_data.lua's, which loads after this
    VehicleData.watch(ONCAR_KEY, {
        id = 'npcs',
        onGained = function(entity, value) standOnCars[entity] = value == true or nil end,
        onLost = function(entity) standOnCars[entity] = nil end,
    })
end)

local function standOnCar(veh) return standOnCars[veh] == true end

--- Such cars near `at`, or nil.
local function onCarsNear(at)
    local out = nil
    for veh in pairs(standOnCars) do
        if DoesEntityExist(veh) and #(GetEntityCoords(veh) - at) <= ONCAR_NEAR then
            out = out or {}
            out[#out + 1] = veh
        end
    end
    return out
end

--- The such car this ped is on: fixed to it already (by the game that owned it before), standing on it, or a little
--- above it (held there); else nil.
local function onCarUnder(ped)
    local att = GetEntityAttachedTo(ped)
    if att and att ~= 0 and GetEntityType(att) == 2 and standOnCar(att) then return att end
    local at = GetEntityCoords(ped)
    local cars = onCarsNear(at)
    if not cars then return nil end
    for _, veh in ipairs(cars) do
        if IsPedOnSpecificVehicle(ped, veh) then return veh end
    end
    local probe = StartExpensiveSynchronousShapeTestLosProbe(at.x, at.y, at.z, at.x, at.y, at.z - ONCAR_PROBE, 2, ped, 7)
    local _, hit, _, _, ent = GetShapeTestResult(probe)
    if hit == 1 or hit == true then
        for _, veh in ipairs(cars) do if veh == ent then return veh end end
    end
    return nil
end

--- May it ride a car now: alive, not sat in one, and nothing taking it anywhere (its step, or one carried on under a
--- Wait: a Wander's walk goes on).
local function mayRide(ped, w)
    local b = w.brain
    if not b or not b.alive or IsPedDeadOrDying(ped, true) then return false end
    if b.ride or b.flee or b.follow or IsPedInAnyVehicle(ped, false) then return false end
    for _, s in ipairs(b.job and b.job.list or {}) do
        if moves(s) then return false end
    end
    local keep = b.job and b.job.keep
    if type(keep) == 'table' and moves(keep) then return false end
    return true
end

-- Turning on it: its hold (where it stands on the car, facing `rot` from the car's way) turned at a ped's pace to
-- what it aims at (faceOn, below: set by the watch, which starts the turn), every frame only while one turns. One off
-- by a little is left as it is (its arms cover that); once turning, it turns until it faces within a few degrees.
local TURN_DEG_S = 300.0   -- how fast it turns
local TURN_FROM  = 12.0    -- off by more than this (degrees), it turns...
local TURN_TO    = 2.0     -- ...until it is within this
local riders, turning = {}, false   -- [netId] = its watch, while it rides on this game

local function hold(h)
    AttachEntityToEntity(h.ped, h.car, 0, h.off.x, h.off.y, h.off.z, 0.0, 0.0, h.rot, false, false, false, true, 2, true)
end

--- How far a rider's hold is off what it faces, in degrees (signed), or nil with nothing to face (or right over it).
local function offOf(h)
    local e = h.faceEnt
    local at = (e and DoesEntityExist(e)) and GetEntityCoords(e) or h.faceAt
    if not at then return nil end
    local me = GetEntityCoords(h.ped)
    local dx, dy = at.x - me.x, at.y - me.y
    if dx * dx + dy * dy < 0.25 then return nil end
    return ((GetHeadingFromVector_2d(dx, dy) - GetEntityHeading(h.car)) - h.rot + 180.0) % 360.0 - 180.0
end

--- A rider's turn this frame; false once it no longer rides here.
local function turnOne(netId, w, dt)
    local h = w.hold
    if watches[netId] ~= w or not h or w.onCar ~= h.car then return false end
    local ped, car = h.ped, h.car
    if not DoesEntityExist(ped) or not DoesEntityExist(car) or not mine(ped) or not IsEntityAttachedToEntity(ped, car) then
        return false
    end
    local diff = offOf(h)
    if not diff then h.turning = false return true end
    local off = math.abs(diff)
    if off <= (h.turning and TURN_TO or TURN_FROM) then h.turning = false return true end
    h.turning = true
    local step = math.min(off, TURN_DEG_S * dt)
    if step <= 0 then return true end
    h.rot =(h.rot + (diff > 0 and step or -step) + 180.0) % 360.0 - 180.0
    hold(h)
    return true
end

--- The frame thread, while a rider turns: it ends once every one faces what it aims at (the watch starts it again).
local function turnRiders()
    if turning then return end
    turning = true
    CreateThread(function()
        local last = GetGameTimer()
        while true do
            local now = GetGameTimer()
            local dt = math.min(0.1, (now - last) / 1000.0)
            last = now
            local any = false
            for netId, w in pairs(riders) do
                if not turnOne(netId, w, dt) then riders[netId] = nil
                elseif w.hold.turning then any = true end
            end
            if not any then break end
            Wait(0)
        end
        turning = false
    end)
end

local function getOff(ped, w)
    if w.onCar and IsEntityAttachedToEntity(ped, w.onCar) then DetachEntity(ped, true, true) end
    w.onCar, w.hold = nil, nil
    riders[w.netId] = nil
end

--- Fixed to the car it stands on while it may ride; let go when it may not, or the car or the hold is gone (and fixed
--- again at once if it is still on a car: a hold lost, the car it is on now).
local function ride(ped, w)
    if w.onCar then
        if DoesEntityExist(w.onCar) and IsEntityAttachedToEntity(ped, w.onCar) and mayRide(ped, w) then
            if w.hold and not riders[w.netId] then riders[w.netId] = w turnRiders() end
            return
        end
        getOff(ped, w)
    end
    if not mayRide(ped, w) then
        -- Fixed to a stand-on car by the game that owned it before, which handed it over at a moment it may not ride (a
        -- Go To just sent, or killed): let go here, as that game would have.
        local att = GetEntityAttachedTo(ped)
        if att and att ~= 0 and GetEntityType(att) == 2 and standOnCar(att) then DetachEntity(ped, true, true) end
        return
    end
    local car = onCarUnder(ped)
    if not car then return end
    local pc = GetEntityCoords(ped)
    local h = { ped = ped, car = car, off = GetOffsetFromEntityGivenWorldCoords(car, pc.x, pc.y, pc.z),
                rot = GetEntityHeading(ped) - GetEntityHeading(car) }
    FreezeEntityPosition(ped, false)
    hold(h)
    w.onCar, w.hold = car, h
    riders[w.netId] = w
    turnRiders()
end

--- Its animation, once the dictionary is here (a scenario needs none). Asked again on a later brain
--- or task: only while this is still the NPC's animation and the ped still ours.
local function playAnim(ped, w)
    local a = w.brain.anim
    if a.scenario then
        TaskStartScenarioInPlace(ped, a.scenario, 0, true)
        return
    end
    local netId = w.netId
    CreateThread(function()
        local loaded = LoadAnimDict(a.dict, 3000)
        local still = pedFor(netId)
        if watches[netId] ~= w or w.brain.anim ~= a or not mine(still) then return end
        if not loaded then
            TaskStandStill(still, -1)
            return
        end
        TaskPlayAnim(still, a.dict, a.clip, 4.0, -4.0, -1, 1, 0.0, false, false, false)   -- 1: loop
    end)
end

local function standOrGuard(ped, w)
    local b = w.brain
    if type(b.anim) == 'table' then
        playAnim(ped, w)
    elseif b.behaviour == 'guard' then
        TaskGuardCurrentPosition(ped, 15.0, 15.0, true)
    else
        TaskStandStill(ped, -1)
    end
end

--- Not fighting: run from whoever it flees, follow whoever it follows, or go home and stand / guard
--- there (both anchor to where the ped is NOW, so one that has wandered — a fight, GTA's own AI after
--- a task ended, a post moved — walks back to its post first and the watch starts the task there).
local function idle(ped, w)
    local b = w.brain
    w.homeBy, w.following, w.fleeing = nil, false, false
    if b.ride then
        seat(ped, b.ride)   -- it sits: no other task (getting out is the card's, or its tasks')
        return
    end
    if b.flee then
        local from = pedOfServerId(b.flee)
        if from then
            TaskSmartFleePed(ped, from, FLEE_FAR, -1, false, false)
            w.fleeing = true
        else
            TaskStandStill(ped, -1)   -- they are down or out of sight: it stays where it ran to
        end
        return
    end
    if b.follow then
        local lead = pedOfServerId(b.follow)
        if lead and w.canMove then
            TaskFollowToOffsetOfEntity(ped, lead, 0.0, -1.5, 0.0, (PACE[b.pace] or PACE.walk).blend, -1, 2.0, true)
            w.following = true
        else
            TaskStandStill(ped, -1)   -- they are gone (or down): it waits where it is
        end
        return
    end
    local post = w.post
    if w.canMove and post and not w.onCar then
        local d = flatDistance(ped, post)
        if d > HOME_RANGE then
            local pace = PACE[b.pace] or PACE.walk
            TaskFollowNavMeshToCoord(ped, post.x, post.y, post.z, pace.blend, -1, 0.5, 0, post.h or 0.0)
            w.homeBy = GetGameTimer() + math.max(HOME_GIVE_UP, math.floor(d / pace.mps * 2000))
            return
        end
    end
    standOrGuard(ped, w)
end

local attackThing   -- (below, after the weapons it reads)

--- A gun it has with no rounds in THIS game, loaded with `rounds`. GTA hands the next game that owns an NPC the gun
--- it holds but not its ammo: given on one player's game, it reaches another's empty and only clicks (a run another
--- player started, an NPC passing between games as players move). Asked wherever it is sent to fight.
local function loaded(ped, hash, rounds)
    if hash and hash ~= 0 and HasPedGotWeapon(ped, hash, false) and GetAmmoInPedWeapon(ped, hash) < 1 then
        SetPedAmmo(ped, hash, rounds)
    end
end

--- Hold `target` in FOE_GROUP on this game for a moment longer (see FOE_GROUP): only one of whip's own NPCs. A player,
--- another resource's ped, or one whose group this game never set (another game's NPC: its group here is GTA's own)
--- is fought as it is.
local function holdFoe(target)
    if IsPedAPlayer(target) or not NetworkGetEntityIsNetworked(target) then return end
    local g = GetPedRelationshipGroupHash(target)
    if g ~= NPC_GROUP and g ~= FOE_GROUP then return end
    foeUntil[PedToNet(target)] = GetGameTimer() + FOE_HOLD_MS
    if g ~= FOE_GROUP then SetPedRelationshipGroupHash(target, FOE_GROUP) end
end

--- Fight another ped, one of whip's NPCs held as a foe first, or GTA would not take it on. Kept as the NPC's foe (w.foe)
--- so the watch holds it for as long as the fight lasts.
local function fightPed(ped, w, target)
    holdFoe(target)
    w.foe = target
    TaskCombatPed(ped, target, 0, 16)
end

--- Fight whoever it should, or go idle. Answers whether it is fighting.
local function task(ped, w)
    local b = w.brain
    w.retargetAt = GetGameTimer() + RETARGET_MS
    w.attackOver = nil
    -- Running away, it fights nobody.
    local target = not b.flee and (pedOfServerId(b.focus) or nearestTarget(ped, b.targets)) or nil
    if target then
        w.homeBy = nil
        loaded(ped, GetSelectedPedWeapon(ped), 250)
        TaskCombatPed(ped, target, 0, 16)
        return true
    end
    -- Nobody to fight, and a director entity to attack (the Director's NPC Attacks).
    if not b.flee and b.attack and attackThing(ped, w, b.attack) then
        w.homeBy = nil
        return true
    end
    idle(ped, w)
    return false
end

-- ============================================
-- TASKS: the step of its task list the brain carries (server/npcs.lua's TASKS)
-- ============================================
--
-- The job is the instant steps in a row and the step after them that takes time. Run once per job on
-- this game: a brain sent again with the same job (a target changed, a resend) leaves it running. A job
-- this game takes over part-way through (its `since`) runs the lasting step under it first (the wander
-- under a Wait) and only the step that takes time, with what is left of it: the instant ones before it
-- have happened (a teleport again would put a walking NPC back), and a once step (a line, a throw) never
-- runs twice. A step that waits for something (got there, got in) is watched each quarter second and
-- said done to the server, again every two seconds until the next job comes.

local JOB_SAY_MS = 2000
local GAIT = { walk = 1.0, run = 2.0, sprint = 3.0 }
local FULL_AUTO = GetHashKey('FIRING_PATTERN_FULL_AUTO')
local UNARMED = GetHashKey('WEAPON_UNARMED')
local SHOOT_ENT = GetHashKey('SCRIPT_TASK_SHOOT_AT_ENTITY')
local SHOOT_AT = GetHashKey('SCRIPT_TASK_SHOOT_AT_COORD')

--- Attack a thing (the Director's NPC Attacks at a director entity): an NPC or a car (netId), else a point (a prop is
--- each game's own copy, so the server says where it stands, as it does for a spot). An NPC it fights, with its weapon
--- or its fists; anything else it shoots at with its weapon, or with none walks up to. Answers false when there is
--- nothing left to attack (the NPC dead, the car gone or burnt out).
function attackThing(ped, w, a)
    if type(a) ~= 'table' then return false end
    local armed = GetSelectedPedWeapon(ped) ~= UNARMED
    if armed then loaded(ped, GetSelectedPedWeapon(ped), 250) end
    if a.net then
        local e = DirectorKit.entityOfNet(a.net)
        if not e or IsEntityDead(e) then return false end
        if IsEntityAPed(e) then fightPed(ped, w, e)
        elseif armed then TaskShootAtEntity(ped, e, -1, w.firing or FULL_AUTO)
        else TaskGoToEntity(ped, e, -1, 1.5, 2.0, 0, 0) end
        return true
    end
    local at = a.at
    if not at then return false end
    if armed then TaskShootAtCoord(ped, at.x, at.y, at.z, -1, w.firing or FULL_AUTO)
    else TaskGoStraightToCoord(ped, at.x, at.y, at.z, 2.0, -1, 0.0, 1.5) end
    return true
end

--- Is it at a thing now (shooting it, or fighting someone)? Then it is left to it.
local function attacking(ped)
    return IsPedInCombat(ped, 0) or GetScriptTaskStatus(ped, SHOOT_ENT) ~= 7 or GetScriptTaskStatus(ped, SHOOT_AT) ~= 7
end

--- What a step points at: a player's ped, a run's NPC or car (by its netId), or nil. (`tEnt`: an entity of this
--- game's own, the Director's preview in the world builder: client/director_preview.lua.)
local function targetEnt(p)
    if p.tEnt and DoesEntityExist(p.tEnt) then return p.tEnt end
    if p.tSid then return pedOfServerId(p.tSid) end
    return DirectorKit.entityOfNet(p.tNet)
end

--- Where a step points: its target's entity (and coords), or its point.
local function targetAt(p)
    local e = targetEnt(p)
    if e then return GetEntityCoords(e), e end
    if p.tAt then return vector3(p.tAt.x, p.tAt.y, p.tAt.z), nil end
    return nil, nil
end

-- What one riding a car turns to (Turning on it, above): what its step points at (a step that faces), else the foe
-- of its fight, else nothing (it keeps the way it faces).

--- Of these players, the nearest it is fighting, else the nearest.
local function foeOf(ped, sids)
    local here = GetEntityCoords(ped)
    local best, bestD, near, nearD
    for _, sid in ipairs(sids or {}) do
        local p = pedOfServerId(sid)
        if p then
            local d = #(GetEntityCoords(p) - here)
            if IsPedInCombat(ped, p) and (not bestD or d < bestD) then best, bestD = p, d end
            if not nearD or d < nearD then near, nearD = p, d end
        end
    end
    return best or near
end

local function pointOf(ped, s)
    if type(s) ~= 'table' or type(s.p) ~= 'table' then return nil, nil end
    if DirectorSteps.is(s.t, 'faces') then return targetAt(s.p) end
    if s.t == 'fightPlayers' then
        local p = foeOf(ped, s.p.players)
        if p then return GetEntityCoords(p), p end
    end
    return nil, nil
end

local function faceOn(ped, w)
    local h = w.hold
    if not h then return end
    local b, at, e = w.brain, nil, nil
    local job = b.job
    if job then
        local list = job.list or {}
        for i = #list, 1, -1 do
            at, e = pointOf(ped, list[i])
            if at then break end
        end
        if not at then at, e = pointOf(ped, job.keep) end
    elseif IsPedInCombat(ped, 0) then
        e = pedOfServerId(b.focus) or foeOf(ped, b.targets)
    end
    h.faceEnt, h.faceAt = e, (not e) and at or nil
    -- Off by more than a little: it turns (the frame thread, only while it does).
    local off = not h.turning and offOf(h)
    if off and math.abs(off) > TURN_FROM then
        h.turning = true
        turnRiders()
    end
end

--- A car a step names (getIn, warpIn: its netId; the preview's `carEnt`), or nil.
local function carOf(p)
    if p.carEnt and DoesEntityExist(p.carEnt) and GetEntityType(p.carEnt) == 2 then return p.carEnt end
    return DirectorKit.entityOfNet(p.carNet, 2)
end

--- The seat a step names: -2 is the first one free.
local function seatOf(car, n)
    if n ~= -2 then return n end
    for s = -1, GetVehicleMaxNumberOfPassengers(car) - 1 do
        if IsVehicleSeatFree(car, s) then return s end
    end
    return -1
end

--- Play an animation once its dictionary is here (a thread: loading waits), while the job is still this one.
--- `w` is the NPC's watch; the preview's (w.preview) says itself whether it still plays (w.still()).
local function jobAnim(w, dict, clip, loop, ms)
    local netId, jobId = w.netId, not w.preview and w.brain.job.id or nil
    CreateThread(function()
        local ready = LoadAnimDict(dict, 3000)
        local ped
        if w.preview then
            ped = w.ped
            if not ready or not w.still() or not DoesEntityExist(ped) then return end
        else
            ped = pedFor(netId)
            local now = watches[netId]
            if not ready or not mine(ped) or not now or not now.brain.job or now.brain.job.id ~= jobId then return end
        end
        TaskPlayAnim(ped, dict, clip, 4.0, -4.0, loop and -1 or ms, loop and 1 or 0, 0.0, false, false, false)
    end)
end

--- Each step: run(ped, w, s, left) with `left` the ms it has (shortened for a job taken over). Answers
--- what the watch looks at to say it is done, for a step that waits for something.
local STEP = {}

-- A wait faces its point's way first when it has one (a patrol's stop: server/director/routes.lua).
STEP.wait = function(ped, _, s, left)
    local h = type(s.p) == 'table' and tonumber(s.p.heading) or nil
    if h then TaskAchieveHeading(ped, h, math.min(2000, left)) end
end

local NAV_TASK, STRAIGHT_TASK = GetHashKey('SCRIPT_TASK_FOLLOW_NAV_MESH_TO_COORD'), GetHashKey('SCRIPT_TASK_GO_STRAIGHT_TO_COORD')

-- WALKING ON THROUGH A POINT. A Go To with another straight after it (a route's points with no stop between) comes
-- with that one as its `ahead` (server/task_seq.lua). GTA is told not to slow down at its point (ENAV_NO_STOPPING: it
-- also keeps the ped moving while a new path is found), and a little before it gets there this game sets off for the
-- next one by itself (jobDone), so it walks on while the server's next job is on its way. That job's Go To finds it
-- already going there and leaves its walk be.
local NAV_NO_STOPPING = 1
local ONWARD_M = { walk = 1.5, run = 2.5, sprint = 3.5 }   -- this near a point it walks on through, it sets off for the next
local onward = {}   -- [ped] = { at, pace, task, since }: the walk this game set off on by itself, till a step takes it

-- A ROUTE'S LINES (server/director/routes.lua): a Go To that is a leg of a route walked straight carries the point it is
-- drawn from (`leg`). On that line it walks it straight; further off (made somewhere else, back from a fight) it finds
-- its own way to the point first, as a straight line from there could go through a wall.
local LEG_M = 3.0

--- Is the ped within LEG_M of the line from `from` to `to` (flat)?
local function onLeg(ped, from, to)
    local c = GetEntityCoords(ped)
    local dx, dy = to.x - from.x, to.y - from.y
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and math.max(0.0, math.min(1.0, ((c.x - from.x) * dx + (c.y - from.y) * dy) / len2)) or 0.0
    local ex, ey = c.x - (from.x + t * dx), c.y - (from.y + t * dy)
    return ex * ex + ey * ey <= LEG_M * LEG_M
end

--- Set off for a Go To's point, facing `h` at the end. `through`: on through it, without slowing down there.
local function walkTo(ped, p, through, h)
    local a, gait = p.at, GAIT[p.pace] or 1.0
    if p.straight and (type(p.leg) ~= 'table' or onLeg(ped, p.leg, a)) then
        TaskGoStraightToCoord(ped, a.x, a.y, a.z, gait, -1, h, through and 0.0 or 0.5)
        return STRAIGHT_TASK
    end
    TaskFollowNavMeshToCoord(ped, a.x, a.y, a.z, gait, -1, 0.5, through and NAV_NO_STOPPING or 0, h)
    return NAV_TASK
end

--- The way from one point to the next, as a heading.
local function wayOn(from, to) return GetHeadingFromVector_2d(to.x - from.x, to.y - from.y) end

STEP.goTo = function(ped, _, s)
    local a = s.p.at
    local ahead = type(s.ahead) == 'table' and type(s.ahead.at) == 'table' and s.ahead or nil
    local on = onward[ped]
    onward[ped] = nil
    local taskId, since
    if on and on.pace == s.p.pace and math.abs(on.at.x - a.x) + math.abs(on.at.y - a.y) + math.abs(on.at.z - a.z) < 0.1
        and GetScriptTaskStatus(ped, on.task) ~= 7 then
        taskId, since = on.task, on.since   -- (already on its way there: it set off as it walked through the last point)
    else
        -- (Walking on through it: its way at the end is the way on, so GTA has no turn to make there.)
        taskId, since = walkTo(ped, s.p, ahead ~= nil, ahead and wayOn(a, ahead.at) or (a.heading or 0.0)), GetGameTimer()
    end
    -- Done there, or when its walk has ended as near as it could get (a point a little off the paths).
    return { arrive = a, within = 1.2, task = taskId, since = since, ahead = ahead, pace = s.p.pace }
end

--- On through a Go To's point to the next one (jobDone, once there): set off for it now.
local function goOn(ped, look)
    local n = look.ahead
    onward[ped] = { at = n.at, pace = n.pace, task = walkTo(ped, n, true, wayOn(look.arrive, n.at)), since = GetGameTimer() }
end

STEP.wander = function(ped, _, s)
    local c = GetEntityCoords(ped)
    TaskWanderInArea(ped, c.x, c.y, c.z, s.p.radius or 8.0, 0.0, 0.0)
end

STEP.teleport = function(ped, _, s)
    local a = s.p.at
    ClearPedTasksImmediately(ped)
    SetEntityCoordsNoOffset(ped, a.x, a.y, a.z, false, false, false)
    SetEntityHeading(ped, a.heading or 0.0)
end

STEP.face = function(ped, _, s, left)
    local at, e = targetAt(s.p)
    if e then TaskTurnPedToFaceEntity(ped, e, left) elseif at then TaskTurnPedToFaceCoord(ped, at.x, at.y, at.z, left) end
end

STEP.follow = function(ped, _, s)
    local e = targetEnt(s.p)
    if e then TaskFollowToOffsetOfEntity(ped, e, 0.0, -1.5, 0.0, GAIT[s.p.pace] or 1.0, -1, 2.0, true) end
end

STEP.flee = function(ped, _, s)
    local at, e = targetAt(s.p)
    if e then TaskSmartFleePed(ped, e, 100.0, -1, false, false)
    elseif at then TaskSmartFleeCoord(ped, at.x, at.y, at.z, 100.0, -1, false, false) end
end

-- TAKE COVER: to its point, and in cover there, hiding from what the point faces (10 m out along its heading). GTA
-- left to find cover near a place picks its own, often far off, or none: so a cover point of its own is made on the
-- marker, facing its way, low (crouched) or high (against a wall), and the NPC is sent to that one. There and still
-- standing a moment later, it is put in cover where it stands. GTA picks which way a ped in cover faces by itself, so
-- one facing the other way from its step's is put in again, facing its way. In cover and facing its way, the step is
-- done (the watch: `cover`). One cover point an NPC, gone with the NPC.
local coverOf = {}   -- [ped] = the cover point its Take Cover made

local function dropCover(ped)
    local cp = coverOf[ped]
    if cp then RemoveCoverPoint(cp) coverOf[ped] = nil end
end

--- Is the step a thread of it was started for still the one playing (its job on this game; the preview's own say)?
local function stillFor(w)
    if w.preview then return w.still end
    local netId, jobId = w.netId, w.brain.job and w.brain.job.id
    return function()
        local now = watches[netId]
        return now ~= nil and now.brain.job ~= nil and now.brain.job.id == jobId and mine(pedFor(netId))
    end
end

STEP.cover = function(ped, w, s, left)
    local a = s.p.at
    local h = (tonumber(a.heading) or 0.0) + 0.0
    local r = math.rad(h)
    local fx, fy = a.x - math.sin(r) * 10.0, a.y + math.cos(r) * 10.0
    local faceLeft = s.p.side == 'left'
    local still = stillFor(w)
    dropCover(ped)
    -- (2: a wall to both sides; 1 / 0: high / low; 0: a 180° arc; a priority point.)
    local cp = AddCoverPoint(a.x + 0.0, a.y + 0.0, a.z + 0.0, h, 2, s.p.height == 'something tall' and 1 or 0, 0, true)
    coverOf[ped] = cp
    TaskSeekCoverToCoverPoint(ped, cp, fx, fy, a.z + 0.0, -1, false)
    local look = { cover = true }
    local function ours() return DoesEntityExist(ped) and coverOf[ped] == cp and still() end
    CreateThread(function()
        local untilAt = GetGameTimer() + math.min(left, 30000)
        local there = false
        while GetGameTimer() < untilAt and ours() do
            if IsPedInCover(ped, false) then there = true break end
            local c = GetEntityCoords(ped)
            if (c.x - a.x) ^ 2 + (c.y - a.y) ^ 2 < 2.25 then
                Wait(1500)
                there = true
                break
            end
            Wait(250)
        end
        if there and ours() then
            local inCover = IsPedInCover(ped, false)
            if not inCover or IsPedInCoverFacingLeft(ped) ~= faceLeft then
                -- TASK_PUT_PED_DIRECTLY_INTO_COVER, by its hash (all eleven of its parameters): its facing forced to
                -- the step's side; the way in played only when it is not in cover yet.
                Citizen.InvokeNative(0x4172393E6BE1FECE, ped, a.x + 0.0, a.y + 0.0, a.z + 0.0, -1, false, 0.5, true, faceLeft,
                                     cp, not inCover)
                Wait(800)
            end
            look.settled = true
        end
        while DoesEntityExist(ped) and coverOf[ped] == cp do Wait(5000) end
        if coverOf[ped] == cp then dropCover(ped) end
    end)
    return look
end

STEP.lookAt = function(ped, _, s, left)
    local at, e = targetAt(s.p)
    local flags = s.p.eyes and 8192 or 0
    if e then TaskLookAtEntity(ped, e, left, flags, 2) elseif at then TaskLookAtCoord(ped, at.x, at.y, at.z, left, flags, 2) end
end

--- A gun in its hand, loaded: the one it holds, else the best it has, else a pistol (an NPC with none aims at nothing).
local PISTOL = GetHashKey('WEAPON_PISTOL')
local function armed(ped)
    if not IsPedArmed(ped, 4) then   -- 4: a gun
        local best = GetBestPedWeapon(ped, false)
        if best and best ~= 0 then SetCurrentPedWeapon(ped, best, true) end
        if not IsPedArmed(ped, 4) then
            GiveWeaponToPed(ped, PISTOL, 120, false, true)
            SetCurrentPedWeapon(ped, PISTOL, true)
        end
    end
    loaded(ped, GetSelectedPedWeapon(ped), 120)
end

STEP.aimAt = function(ped, _, s, left)
    local at, e = targetAt(s.p)
    armed(ped)
    if e then TaskAimGunAtEntity(ped, e, left, false) elseif at then TaskAimGunAtCoord(ped, at.x, at.y, at.z, left, false, false) end
end

-- SHOOT AT, its style for the step: how often it hits, how fast it pulls the trigger (40% is GTA's own pace, 100% ten
-- times it), single shots to full auto, and how good a fighter it is. Its brain set again mid-step keeps them
-- (applyBrain). NPC Attacks' style is the same, for every fight it has (the brain's `style`).
local PATTERN = { ['single shots'] = GetHashKey('FIRING_PATTERN_SINGLE_SHOT'), ['bursts'] = GetHashKey('FIRING_PATTERN_BURST_FIRE'),
                  ['full auto'] = FULL_AUTO }
local SKILL = { ['a rookie'] = 0, ['a pro'] = 1, ['a killer'] = 2 }

-- A KILLER never holds fire. GTA's peds stop shooting by themselves: they duck and flinch when shot at, get pinned
-- down by fire coming their way, fire slower the further off the target is, wait for a clear line, and from cover
-- peek out every few seconds for a short burst (combatbehaviour.meta's in-cover times). A killer has all of that
-- off, keeps its firing pattern, and stays that way on this game for the rest of its life (a fight after its Shoot
-- At included). Numbers: CCombatData's behaviour flags and SET_COMBAT_FLOAT's list.
local function killer(ped, pattern)
    SetPedCombatAttributes(ped, 13, true)    -- BF_Aggressive
    SetPedCombatAttributes(ped, 23, false)   -- BF_RequiresLosToShoot
    SetPedCombatAttributes(ped, 24, false)   -- BF_UseProximityFiringRate
    SetPedCombatAttributes(ped, 26, true)    -- BF_DisableEntryReactions
    SetPedCombatAttributes(ped, 30, true)    -- BF_CanShootWithoutLOS
    SetPedCombatAttributes(ped, 35, true)    -- BF_DisablePinnedDown
    SetPedCombatAttributes(ped, 38, true)    -- BF_DisableBulletReactions
    SetCombatFloat(ped, 1, 10.0)             -- CCF_BURST_DURATION_IN_COVER
    SetCombatFloat(ped, 3, 0.1)              -- CCF_TIME_BETWEEN_BURSTS_IN_COVER
    SetCombatFloat(ped, 4, 0.5)              -- CCF_TIME_BETWEEN_PEEKS
    SetCombatFloat(ped, 7, 1.0)              -- CCF_FIGHT_PROFICIENCY
    SetPedAlertness(ped, 3)
    SetPedFiringPattern(ped, pattern)
end

local function shooting(ped, p)
    SetPedAccuracy(ped, math.max(0, math.min(100, math.floor(tonumber(p.accuracy) or 30))))
    local r = math.max(10, math.min(100, tonumber(p.rate) or 40))
    SetPedShootRate(ped, math.floor(r <= 40 and r * 2.5 or 100 + (r - 40) * 15))
    SetPedCombatAbility(ped, SKILL[p.skill] or 1)
    local pattern = PATTERN[p.pattern] or FULL_AUTO
    if p.skill == 'a killer' then killer(ped, pattern) end
    return pattern
end

STEP.shootAt = function(ped, _, s, left)
    local at, e = targetAt(s.p)
    armed(ped)
    local pattern = shooting(ped, s.p)
    if e then TaskShootAtEntity(ped, e, left, pattern) elseif at then TaskShootAtCoord(ped, at.x, at.y, at.z, left, pattern) end
end

-- What Throw hands it (server/director/tasks.lua's options).
local THROWN = { ['grenade'] = 'WEAPON_GRENADE', ['molotov'] = 'WEAPON_MOLOTOV', ['smoke grenade'] = 'WEAPON_SMOKEGRENADE',
                 ['flare'] = 'WEAPON_FLARE', ['snowball'] = 'WEAPON_SNOWBALL', ['ball'] = 'WEAPON_BALL' }

-- THROW: what it throws, its model loaded first (one not loaded flies unseen and never goes off: only the flare, which
-- the game keeps loaded, worked), at its target, and put away after, what it held before back in its hand.
-- THROWS ONE AFTER ANOTHER are one run of throws (throwOf): the last one tidies up, every item the run gave put away and
-- what it held before the first back in its hand. Each throw tidying up after itself put the next one's item away in the
-- middle of its throw. What it holds then is left alone unless it is one of them or nothing (a Shoot At after armed it).
local throwOf = {}   -- [ped] = { before = the weapon held before the run, given = { [hash] = true } } of the throw going on

STEP.throw = function(ped, w, s)
    local at = targetAt(s.p)
    if not at then return end
    local hash = GetHashKey(THROWN[s.p.item] or 'WEAPON_GRENADE')
    local was = throwOf[ped]
    local rec = { before = was and was.before or nil, given = was and was.given or {} }
    throwOf[ped] = rec
    local still = stillFor(w)
    -- The run's tidy-up, by its last throw: its items put away, what it held before back in its hand.
    local function tidy()
        throwOf[ped] = nil
        if not DoesEntityExist(ped) then return end
        local held = GetSelectedPedWeapon(ped)
        for h in pairs(rec.given) do RemoveWeaponFromPed(ped, h) end
        if not (rec.given[held] or held == UNARMED or held == 0) then return end
        local before = rec.before
        if before and before ~= 0 and not rec.given[before] and HasPedGotWeapon(ped, before, false) then
            SetCurrentPedWeapon(ped, before, true)
        else
            SetCurrentPedWeapon(ped, UNARMED, true)
        end
    end
    CreateThread(function()
        -- Its asset held for the throw (counted: streaming.lua), given back once it is over
        LoadWeaponAsset(hash, 3000)
        SetTimeout(6000, function() ReleaseWeaponAsset(hash) end)
        if throwOf[ped] ~= rec then return end   -- another throw came after: it throws and tidies up
        -- (Asked again after the load: its job over, or the NPC another game's now, it throws nothing; what an earlier
        -- throw of the run gave is put away.)
        if not DoesEntityExist(ped) or not still() then tidy() return end
        if rec.before == nil then rec.before = GetSelectedPedWeapon(ped) end
        rec.given[hash] = true
        GiveWeaponToPed(ped, hash, 1, false, true)
        SetCurrentPedWeapon(ped, hash, true)
        -- TASK_THROW_PROJECTILE: FiveM's wrapper declares fewer parameters than the game reads.
        Citizen.InvokeNative(0x7285951DBF6B5A51, ped, at.x + 0.0, at.y + 0.0, at.z + 0.0, 0, false)
        Wait(2500)
        if throwOf[ped] ~= rec then return end   -- another throw came after: it tidies up
        tidy()
    end)
end

STEP.fightPlayers = function(ped, _, s)
    local target = nearestTarget(ped, s.p.players)
    loaded(ped, GetSelectedPedWeapon(ped), 250)
    if target then TaskCombatPed(ped, target, 0, 16) end
end

STEP.fightNpc = function(ped, w, s)
    local e = targetEnt(s.p)
    loaded(ped, GetSelectedPedWeapon(ped), 250)
    if e then fightPed(ped, w, e) end
end

STEP.emote = function(ped, w, s, left)
    local a = s.p.anim
    if type(a) ~= 'table' then return end
    if a.scenario then TaskStartScenarioInPlace(ped, a.scenario, 0, true)
    else jobAnim(w, a.dict, a.clip, true, left) end
end

STEP.anim = function(_, w, s, left)
    jobAnim(w, s.p.dict, s.p.clip, s.p.loop ~= false, left)
end

STEP.scenario = function(ped, _, s)
    TaskStartScenarioInPlace(ped, s.p.scenario, 0, true)
end

-- In its own voice, or the one picked (one that has not got the line says nothing).
STEP.speech = function(ped, _, s)
    local voice = s.p.voice
    if type(voice) == 'string' and voice ~= '' then
        PlayPedAmbientSpeechWithVoiceNative(ped, s.p.line, voice, 'SPEECH_PARAMS_FORCE_NORMAL', false)
    else
        PlayPedAmbientSpeechNative(ped, s.p.line, 'SPEECH_PARAMS_FORCE_NORMAL')
    end
end

--- The car a step names, waited for (up to CAR_WAIT_MS) while this game has not got it yet: one the run made a moment
--- ago reaches each game a little after the server has it (a run that makes a car and seats its NPC at once, on a far
--- connection). fn(car) once it is here, while the step is still this NPC's; never when it does not come. Answers
--- whether it was here already.
local CAR_WAIT_MS = 8000
local function withCar(w, p, fn)
    local car = carOf(p)
    if car then fn(car) return true end
    local still = stillFor(w)
    CreateThread(function()
        local untilAt = GetGameTimer() + CAR_WAIT_MS
        while GetGameTimer() < untilAt do
            Wait(100)
            if not still() then return end
            car = carOf(p)
            if car then fn(car) return end
        end
    end)
    return false
end

STEP.getIn = function(ped, w, s)
    local look = { waitCarUntil = GetGameTimer() + CAR_WAIT_MS }
    withCar(w, s.p, function(car)
        TaskEnterVehicle(ped, car, 20000, seatOf(car, s.p.seatN or -1), 1.0, 1, 0)
        look.inCar = car
    end)
    return look
end

STEP.getOut = function(ped)
    local veh = GetVehiclePedIsIn(ped, false)
    if veh ~= 0 then TaskLeaveVehicle(ped, veh, 0) end
    return { outOfCar = true }
end

STEP.warpIn = function(ped, w, s)
    withCar(w, s.p, function(car) SetPedIntoVehicle(ped, car, seatOf(car, s.p.seatN or -1)) end)
end

STEP.driveTo = function(ped, _, s)
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return { failed = true } end
    local a = s.p.at
    TaskVehicleDriveToCoordLongrange(ped, veh, a.x, a.y, a.z, s.p.mps or 15.0, s.p.styleN or 786603, 8.0)
    return { arrive = a, within = 10.0, flat = true }
end

STEP.cruise = function(ped, _, s)
    local veh = GetVehiclePedIsIn(ped, false)
    if veh ~= 0 then TaskVehicleDriveWander(ped, veh, s.p.mps or 14.0, s.p.styleN or 786603) end
end

STEP.followCar = function(ped, _, s)
    local veh = GetVehiclePedIsIn(ped, false)
    local e = targetEnt(s.p)
    if veh ~= 0 and e then TaskVehicleFollow(ped, veh, e, s.p.mps or 22.0, 786603, 10) end
end

STEP.setHealth = function(ped, _, s)
    local max = GetEntityMaxHealth(ped)
    SetEntityHealth(ped, math.max(101, math.floor(100 + (max - 100) * (s.p.pct or 100) / 100)))
end

STEP.die = function(ped)
    SetEntityInvincible(ped, false)
    SetEntityHealth(ped, 0)
end

--- Up again as it was. GTA keeps a ped that writhed or died hurt through a resurrect (it limps and clutches itself, as
--- if on low health): its injured and hurt flags off, its walk back to its own, its blood gone.
local function unhurt(ped)
    SetPedConfigFlag(ped, 166, false)   -- CPED_CONFIG_FLAG_IsInjured
    SetPedConfigFlag(ped, 187, false)   -- CPED_CONFIG_FLAG_HasHurtStarted
    ResetPedMovementClipset(ped, 0.0)
    ClearPedBloodDamage(ped)
end

STEP.revive = function(ped, w)
    if IsPedDeadOrDying(ped, true) then ResurrectPed(ped) end
    ClearPedTasksImmediately(ped)
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    unhurt(ped)
    w.deadSent = false
end

STEP.writhe = function(ped, _, s, left)
    -- TASK_WRITHE: FiveM's wrapper declares fewer parameters than the game reads. At the nearest player.
    local target = nearestTarget(ped, s.p.players) or PlayerPedId()
    Citizen.InvokeNative(0xCDDC2B77CE54AC6E, ped, target, left, 0, false, 0)
end

STEP.freeze = function() end   -- (the job's `frozen`: the watch holds it, shouldFreeze)

STEP.weapon = function(ped, _, s)
    if s.p.weapon == '' then SetCurrentPedWeapon(ped, UNARMED, true) return end
    local hash = GetHashKey(s.p.weapon)
    if not HasPedGotWeapon(ped, hash, false) then GiveWeaponToPed(ped, hash, 250, false, true) end
    SetCurrentPedWeapon(ped, hash, true)
    loaded(ped, hash, 250)
end

--- Another resource's step (Whip.task): played by that resource's own code (client/director_tasks.lua).
local function satStep(ped, w, s, left) return DirectorTaskSteps.run(ped, 'npc', s, left, w.preview) end

--- A step's code: whip_core's, or another resource's.
local function stepOf(t)
    return STEP[t] or (DirectorTaskSteps.isSatellite(t) and satStep) or nil
end

--- A job's steps from `from` on (runJob). A Warp Into a car this game has not got yet (made a moment ago, on a far
--- connection) holds the steps after it until the car is here (withCar): a Drive To played the same moment found the
--- ped on foot and failed, and a Cruise or a Follow did nothing.
local function runSteps(ped, w, list, from, since, resumed)
    for i = from, #list do
        local s = list[i]
        local run = stepOf(s.t)
        local skip = resumed and (s.timing == 'instant' or s.once)
        if run and not skip then
            if s.t == 'warpIn' and i < #list and not carOf(s.p) then
                withCar(w, s.p, function(car)
                    SetPedIntoVehicle(ped, car, seatOf(car, s.p.seatN or -1))
                    runSteps(ped, w, list, i + 1, since, resumed)
                end)
                return
            end
            local left = math.max(100, (s.ms or s.giveUpMs or 10000) - (i == #list and since or 0))
            local ok, watchFor = pcall(run, ped, w, s, left)
            if not ok then
                print(('[whip_core:npcs] NPC %s: task %s failed here: %s'):format(tostring(w.id), tostring(s.t), tostring(watchFor)))
            elseif i == #list and s.timing == 'until' then
                w.watchJob = watchFor or {}
            end
        end
    end
    onward[ped] = nil   -- (a walk it set off on by itself: its Go To above took it, or another step is playing)
end

--- Run the job, once per job on this game (see the section's head).
local function runJob(ped, w)
    local job = w.brain.job
    if w.ran == job.id then return end
    w.ran, w.watchJob, w.saidAt = job.id, nil, nil
    local since = tonumber(job.since) or 0
    local resumed = since > 0
    local list = job.list or {}
    local last = list[#list]
    -- Taken over part-way: what lasts first (its walk round under a Wait), then only the step that takes time.
    if resumed and job.keep and stepOf(job.keep.t) and (not last or last.t == 'wait') then
        pcall(stepOf(job.keep.t) --[[@as function]], ped, w, job.keep, math.max(1000, (job.keep.ms or 10000)))
    end
    runSteps(ped, w, list, 1, since, resumed)
end

--- A step that waits for something: is it done here? 'done', 'failed' or nil.
local function jobDone(ped, look)
    if not look then return nil end
    if look.failed then return 'failed' end
    if look.sat then return DirectorTaskSteps.done(ped, look) end
    if look.arrive then
        local a = look.arrive
        local c = GetEntityCoords(ped)
        local veh = look.flat and GetVehiclePedIsIn(ped, false) or 0
        if veh ~= 0 then c = GetEntityCoords(veh) end
        local dx, dy, dz = c.x - a.x, c.y - a.y, look.flat and 0.0 or (c.z - a.z)
        -- (Walking on through it: done a little before, as it sets off for the next.)
        local within = look.ahead and math.max(look.within, ONWARD_M[look.pace] or ONWARD_M.walk) or look.within
        local there = dx * dx + dy * dy <= within * within and math.abs(dz) <= 2.0
        -- Its walk over (7: no such task now) a second in and within a few metres: as near as the paths go.
        if not there and look.task and GetGameTimer() - look.since >= 1000 and GetScriptTaskStatus(ped, look.task) == 7
            and dx * dx + dy * dy <= 16.0 then
            there = true
        end
        if not there then return nil end
        if look.ahead and not look.wentOn then
            look.wentOn = true
            goOn(ped, look)
        end
        return 'done'
    end
    if look.cover then return look.settled and 'done' or nil end   -- in cover, facing its way (STEP.cover)
    if look.inCar then return IsPedInVehicle(ped, look.inCar, false) and 'done' or nil end
    -- (Get In whose car never reached this game: STEP.getIn's wait for it.)
    if look.waitCarUntil then return GetGameTimer() >= look.waitCarUntil and 'failed' or nil end
    if look.outOfCar then return not IsPedInAnyVehicle(ped, false) and 'done' or nil end
    return nil
end

--- The Director's preview in the world builder (client/director_preview.lua): a step on a ped of this game's own,
--- by the same steps a run plays. `w` = { preview = true, ped, still = fn }: an animation goes on only while still()
--- says the preview plays. run answers what to watch for a step that waits; done says if it is (as jobDone).
NpcSteps = {
    run = function(ped, w, s, left)
        local fn = stepOf(s.t)
        if not fn then return nil end
        return fn(ped, w, s, left)
    end,
    done = function(ped, look) return jobDone(ped, look) end,
    --- The copy back as it was placed (the preview puts it back): its cover point gone, unhurt, nothing in its hands.
    reset = function(ped)
        dropCover(ped)
        unhurt(ped)
        throwOf[ped] = nil   -- (a throw still waiting to tidy up has nothing left to do: its items go below)
        onward[ped] = nil
        RemoveAllPedWeapons(ped, true)
    end,
}

local function applyBrain(ped, w)
    local b = w.brain
    local c = b.conditions or {}
    local flees = c.flees == true or b.flee ~= nil         -- by nature, or told to run (NPC Runs Away)
    -- (One a fight on this game holds as its foe stays so: see FOE_GROUP.)
    SetPedRelationshipGroupHash(ped, (foeUntil[w.netId] or 0) > GetGameTimer() and FOE_GROUP or NPC_GROUP)
    SetBlockingOfNonTemporaryEvents(ped, not c.reacts)    -- blocked, it reacts to nothing (fleeing too)
    SetPedCombatAttributes(ped, 5, not flees)             -- CA_ALWAYS_FIGHT
    SetPedCombatAttributes(ped, 17, flees)                -- CA_ALWAYS_FLEE
    SetPedCombatAttributes(ped, 46, true)                 -- CA_CAN_FIGHT_ARMED_PEDS_WHEN_NOT_ARMED
    SetPedCombatAttributes(ped, 58, not flees)            -- CA_DISABLE_FLEE_FROM_COMBAT
    -- After a player in a car, on foot: not looking for a car of their own, never taking one (NPC
    -- drivers are not whip's yet), allowed to chase on foot, and pressing in rather than holding a spot.
    -- Numbers: FiveM's eCombatAttribute list and SET_PED_COMBAT_MOVEMENT (2 = offensive).
    SetPedCombatAttributes(ped, 1, false)                 -- CA_USE_VEHICLE
    SetPedCombatAttributes(ped, 41, false)                -- CA_CAN_COMMANDEER_VEHICLES
    SetPedCombatAttributes(ped, 21, true)                 -- CA_CAN_CHASE_TARGET_ON_FOOT
    SetPedCombatMovement(ped, 2)
    SetPedCombatAbility(ped, 1)
    SetPedCombatRange(ped, 1)
    SetPedAccuracy(ped, 30)
    -- How it fights, every fight (NPC Attacks' style): as a Shoot At shoots, and its fire on what it attacks (w.firing).
    w.firing = nil
    if type(b.style) == 'table' then
        w.firing = shooting(ped, b.style)
        SetPedFiringPattern(ped, w.firing)
    end
    -- (A Shoot At playing keeps its own aim and trigger finger.)
    local jl = b.job and b.job.list
    local last = jl and jl[#jl]
    if last and last.t == 'shootAt' and type(last.p) == 'table' then shooting(ped, last.p) end
    SetPedDropsWeaponsWhenDead(ped, false)                -- before the gun: a dropped one is a real, untracked pickup
    SetEntityInvincible(ped, c.invincible == true)
    SetPedKeepTask(ped, true)
    -- Riding (a take's driver or passenger): never knocked out, thrown through the windscreen or dragged out.
    local riding = b.ride ~= nil
    SetPedCanBeKnockedOffVehicle(ped, riding and 1 or 0)
    SetPedConfigFlag(ped, 32, not riding)
    SetPedCanBeDraggedOut(ped, not riding)
    -- What it holds: a Hold a Weapon step's choice (b.held, server state: '' put away), else its own gun. A brain sent
    -- again keeps the step's, and every game that takes it over puts it in its hands.
    local rounds = 250
    if b.held ~= nil then
        if b.held == '' then
            SetCurrentPedWeapon(ped, UNARMED, true)
        else
            local hash = GetHashKey(b.held)
            if not HasPedGotWeapon(ped, hash, false) then GiveWeaponToPed(ped, hash, rounds, false, true) end
            SetCurrentPedWeapon(ped, hash, true)
        end
    elseif b.weapon and b.weapon.name then
        local hash = GetHashKey(b.weapon.name)
        rounds = b.weapon.ammo or 250
        if not HasPedGotWeapon(ped, hash, false) then GiveWeaponToPed(ped, hash, rounds, false, true) end
        SetCurrentPedWeapon(ped, hash, true)
    end
    -- (Its gun from the game that owned it before arrives here empty: loaded again, whichever it is. One given none
    -- stays so.)
    if rounds > 0 then loaded(ped, GetSelectedPedWeapon(ped), rounds) end
    -- Its armour at birth: sent only until a game has applied it (server/npcs.lua armourDue).
    if type(b.armour) == 'number' and b.armour > 0 then SetPedArmour(ped, math.floor(b.armour)) end
    -- What it wears (its page's Outfit): put on by its owner, as only the owner can (the others see what this game sends).
    if b.outfit then PedOutfit.apply(ped, PedOutfit.read(b.outfit)) end
    -- One that cannot move stands exactly on its post. The server's freeze is an RPC queued until a game owns the ped,
    -- and in between, a spot touching a bush or a counter has GTA's physics push it out sideways or up. Back on its post
    -- (and its heading) as the freeze goes on, by every game that takes it over. Not one waiting on its interior (the
    -- gate's release does that), not a corpse, and not one on a car it rides (fixed to the car first: ride). Once a post
    -- on this game: a brain sent again (a state change) must not pull it back off where its tasks put it (a Teleport)
    -- or out of a seat; nor while its tasks run.
    ride(ped, w)
    faceOn(ped, w)
    local post = w.post
    local postKey = post and ('%.2f %.2f %.2f'):format(post.x, post.y, post.z) or nil
    if not w.canMove and post and b.alive and not (w.gate and not w.ready) and not w.onCar and not b.job
        and w.snapped ~= postKey and not IsPedInAnyVehicle(ped, false) then
        w.snapped = postKey
        local pos = GetEntityCoords(ped)
        if flatDistance(ped, post) > 0.15 or math.abs(pos.z - post.z) > 0.3 then
            SetEntityCoordsNoOffset(ped, post.x, post.y, post.z, false, false, false)
        end
        if post.h and math.abs(((GetEntityHeading(ped) - post.h) + 180.0) % 360.0 - 180.0) > 5.0 then
            SetEntityHeading(ped, post.h)
        end
    end
    FreezeEntityPosition(ped, shouldFreeze(w))
    -- Its tasks' step while one runs (even dead: a Revive), else what it does by itself.
    if b.job then
        runJob(ped, w)
    else
        w.ran, w.watchJob = nil, nil
        if b.alive then task(ped, w) end
    end
end

--- Is the ped where its MLO matters: at its post, not walking there or taken out of it (follow, run
--- away, a post moved)? Away from it, the interior there has no say over it (an NPC led out of a house
--- must not freeze on the street).
local function atPost(ped, post) return post ~= nil and flatDistance(ped, post) <= GATE_NEAR end

--- The interior is here and settled (or the ped is away from it): let the ped go, putting it back if
--- it fell through the floor at its post before this game froze it (it was handed over without the
--- interior).
local function release(ped, w)
    w.ready, w.settleAt = true, nil
    local post = w.post
    if post and flatDistance(ped, post) <= FELL_FLAT and GetInteriorFromEntity(ped) == 0
        and GetEntityCoords(ped).z < post.z - FELL_BY then
        SetEntityCoordsNoOffset(ped, post.x, post.y, post.z, false, false, false)
        SetEntityHeading(ped, post.h or 0.0)
    end
    FreezeEntityPosition(ped, shouldFreeze(w))
end

--- One look at an NPC this game owns: its death, its target, its walk home, its interior. Answers false once this game
--- no longer runs it (its watch ends).
local function look(netId, w, now)
    local ped = pedFor(netId)
    if not mine(ped) then return false end
    local dead = IsPedDeadOrDying(ped, true)

    if dead and not w.deadSent then
        w.deadSent = true
        TriggerServerEvent('whip_core:server:npcDied', w.id, netId)
    end

    if w.gate and w.post and not atPost(ped, w.post) then
        if not w.ready then release(ped, w) end   -- away from its MLO: nothing to wait for
    elseif w.gate and w.post then
        local here = standsAt(w.gateAt)
        if not w.ready then
            if here and HasCollisionLoadedAroundEntity(ped) then
                w.settleAt = w.settleAt or (now + SETTLE_MS)
                if now >= w.settleAt then release(ped, w) end
            else
                w.settleAt = nil
            end
        elseif not here then
            w.ready, w.settleAt = false, nil      -- its floor went (the interior unloaded): hold it until it is back
            FreezeEntityPosition(ped, true)
        end
    end

    -- On a car players can stand on: fixed to it (or let go of: ride), turned to what it aims at.
    ride(ped, w)
    faceOn(ped, w)
    -- Frozen or not is the brain's, every quarter second: the server's own hold at spawn is an
    -- RPC queued until the ped has an owner, so it can land after this game let the ped go.
    local want = shouldFreeze(w)
    if IsEntityPositionFrozen(ped) ~= want then FreezeEntityPosition(ped, want) end

    -- The NPC it fights stays its foe while the fight is on; held as one by a fight here that has ended,
    -- it has its own group back (see FOE_GROUP).
    if w.foe and DoesEntityExist(w.foe) and IsPedInCombat(ped, w.foe) then holdFoe(w.foe) end
    if foeUntil[netId] and foeUntil[netId] <= now then
        foeUntil[netId] = nil
        if GetPedRelationshipGroupHash(ped) == FOE_GROUP then SetPedRelationshipGroupHash(ped, NPC_GROUP) end
    end

    local b = w.brain
    -- Its tasks' step: a step that waits for something is said done (again every two seconds, until
    -- the next job comes). Nothing else is done for it meanwhile: the server ends the tasks when it
    -- should fight.
    if b.job then
        local how = jobDone(ped, w.watchJob)
        if how and now >= (w.saidAt or 0) then
            w.saidAt = now + JOB_SAY_MS
            TriggerServerEvent('whip_core:server:npcJob', w.id, netId, b.job.id, how)
        end
    elseif not dead and b.alive and not (w.gate and not w.ready) then
        local target
        if not b.flee and #(b.targets or {}) > 0 and now >= (w.retargetAt or 0) and not IsPedInCombat(ped, 0) then
            w.retargetAt = now + RETARGET_MS
            target = pedOfServerId(b.focus) or nearestTarget(ped, b.targets)
        end
        if target then
            w.homeBy = nil
            loaded(ped, GetSelectedPedWeapon(ped), 250)
            TaskCombatPed(ped, target, 0, 16)      -- someone came into range, or got back up
        elseif b.attack and not b.flee and not w.attackOver and #(b.targets or {}) == 0
            and now >= (w.retargetAt or 0) and not attacking(ped) then
            -- What it attacks again (its fight over, or the shooting stopped); none left to attack: home.
            w.retargetAt = now + RETARGET_MS
            if not attackThing(ped, w, b.attack) then
                w.attackOver = true
                idle(ped, w)
            end
        elseif w.homeBy and (flatDistance(ped, w.post) <= HOME_RANGE or now >= w.homeBy) then
            w.homeBy = nil                         -- home (or given up): stand / guard here
            standOrGuard(ped, w)
        elseif b.follow and not b.flee and not w.following and w.canMove and pedOfServerId(b.follow) then
            idle(ped, w)                           -- whoever it follows is back (up, or in range)
        elseif b.flee and not w.fleeing and pedOfServerId(b.flee) then
            idle(ped, w)                           -- whoever it ran from is back: it runs again
        elseif b.ride and not IsPedInCombat(ped, 0) then
            seat(ped, b.ride)                      -- riding: back in its seat if it came out of it
        end
    end
    return true
end

--- While this game owns NPCs: ONE loop looks at each of them every quarter second (a thread per NPC woke the
--- scheduler four times a second for each), ending with the last. One whose look fails is let go, said once.
local watching = false
local function watch()
    if watching then return end
    watching = true
    CreateThread(function()
        while next(watches) do
            local now = GetGameTimer()
            local ids = {}
            for netId in pairs(watches) do ids[#ids + 1] = netId end
            for _, netId in ipairs(ids) do
                local w = watches[netId]
                if w then
                    local ok, keep = pcall(look, netId, w, now)
                    if not ok then
                        print(('[whip_core:npcs] NPC %s: its watch failed and was let go: %s'):format(tostring(w.id), tostring(keep)))
                    end
                    if (not ok or not keep) and watches[netId] == w then watches[netId] = nil end
                end
            end
            Wait(250)
        end
        watching = false
    end)
end

RegisterNetEvent('whip_core:client:npcBrain', function(id, netId, ver, b)
    if type(b) ~= 'table' then return end
    local ped = pedFor(netId)
    if not mine(ped) then return end   -- not here yet, or not ours: the server sends it again
    local w = watches[netId]
    local fresh = (w == nil)
    if fresh then w = { id = id, netId = netId, ready = false, deadSent = false }; watches[netId] = w end
    w.id, w.brain, w.gate = id, b, b.gate == true
    if b.alive and w.deadSent then w.deadSent = false end   -- up again (its tasks' Revive): a later death is said too
    w.post = type(b.post) == 'table' and b.post or nil
    w.gateAt = type(b.gateAt) == 'table' and b.gateAt or w.post   -- where its MLO is looked for
    w.canMove = not (b.conditions and b.conditions.canMove == false)
    if not w.gate then
        w.ready = true
    elseif fresh then
        -- Its MLO already loaded here (or it is away from it): no hold, whether it was just made (the
        -- server's own hold then is only a safety freeze) or handed over in the middle of a fight. The
        -- two-second hold is for an interior that only just came.
        w.ready = not atPost(ped, w.post) or (standsAt(w.gateAt) and HasCollisionLoadedAroundEntity(ped))
    end
    applyBrain(ped, w)
    if fresh then watch() end
    TriggerServerEvent('whip_core:server:npcApplied', id, netId, ver)
end)

--- The server asks the owner to take the ped away (the owner can, and a server delete out from
--- under it can be sent back). The model must match, in case the id now names something else.
RegisterNetEvent('whip_core:client:npcDelete', function(netId, model)
    local ped = pedFor(netId)
    if not mine(ped) then return end
    if (GetEntityModel(ped) % 0x100000000) ~= ((tonumber(model) or 0) % 0x100000000) then return end
    watches[netId] = nil
    SetEntityAsMissionEntity(ped, true, true)
    DeleteEntity(ped)
end)

-- ============================================
-- MLO NPCs: freeze one the moment this game owns it
-- ============================================

--- A gated NPC this game owns, whose brain has not arrived yet: hold it while the interior or the
--- collision under it is missing. (Once the brain is here, the watch does this.)
local function startGates()
    if gateThread then return end
    gateThread = true
    CreateThread(function()
        while next(gates) do
            local near = false
            for netId, g in pairs(gates) do
                local ped = pedFor(netId)
                if ped then
                    near = true
                    if not watches[netId] and mine(ped) and atPost(ped, g.at)
                        and not (standsAt(g.at) and HasCollisionLoadedAroundEntity(ped)) then
                        FreezeEntityPosition(ped, true)
                    end
                end
            end
            Wait(near and 100 or 1000)
        end
        gateThread = false
    end)
end

local function readAt(at)
    if type(at) ~= 'table' or type(at.x) ~= 'number' or type(at.y) ~= 'number' or type(at.z) ~= 'number' then return nil end
    return { x = at.x, y = at.y, z = at.z }
end

-- Every gated NPC, when this character loads.
RegisterNetEvent('whip_core:client:npcGates', function(list)
    gates = {}
    for _, g in ipairs(type(list) == 'table' and list or {}) do
        local at = type(g) == 'table' and readAt(g.at)
        if at and type(g.netId) == 'number' then gates[g.netId] = { id = g.id, at = at } end
    end
    if next(gates) then startGates() end
end)

RegisterNetEvent('whip_core:client:npcGate', function(id, netId, at)
    at = readAt(at)
    if not at or type(netId) ~= 'number' then return end
    gates[netId] = { id = id, at = at }
    startGates()
end)

RegisterNetEvent('whip_core:client:npcGateGone', function(netId)
    if type(netId) == 'number' then gates[netId] = nil end
end)

-- ============================================
-- /npcdebug: what each NPC near you is doing (a dev tool)
-- ============================================
--
-- The server's view comes once a second (server/npcs.lua: owner, brain applied, frozen, task); this
-- game adds its own (its brain's wishes, its MLO hold and what it finds there). Drawn above each NPC,
-- and each NPC's lines printed to F8 when they change, to copy. Text must be drawn every frame, so this
-- loop runs every frame, but only while the overlay is on.

local debugList = nil
local debugPrinted = {}

local function yn(b) return b and 'yes' or 'no' end

--- What the server knows of it: is its ped there, does its id still lead to it, its health as read
--- there (and whether a real read has come in yet), its orphan mode and routing bucket.
local function serverLine(e)
    if not e.exists then return '~r~server: its ped is GONE~w~' end
    return ('server: id %s  hp %s/%s %s  orphan %s  bucket %s%s'):format(
        e.idOk and 'ok' or '~r~names something else~w~', tostring(e.hp), tostring(e.maxHp),
        e.synced and '(read)' or '~o~(no real read yet)~w~', tostring(e.orphan), tostring(e.bucket),
        e.ours and '' or '  ~r~whip: not its ped~w~')
end

--- A task list's line: its step, whether its game has it, how long it has run.
local function jobLine(j)
    local step = j.last and j.last ~= j.i and ('%d-%d'):format(j.i, j.last) or tostring(j.i)
    return ('~y~%s~w~ step %s/%d %s  job %s: %s%s'):format(j.idle and 'patrol' or 'tasks', step, j.n, tostring(j.t), tostring(j.id),
        j.applied and ('~g~applied~w~ %.1f s'):format((j.ms or 0) / 1000) or '~r~not applied yet~w~',
        j.reported and ('  said ' .. tostring(j.reported)) or '')
end

local function debugLines(e, ped)
    local meSid = GetPlayerServerId(PlayerId())
    local owner = e.owner == meSid and '~g~you~w~' or (e.owner == 0 and '~r~nobody yet~w~' or ('player ' .. tostring(e.owner)))
    local brain = e.acked == e.ver and 'applied' or ('~r~not applied~w~ (' .. tostring(e.acked) .. '/' .. tostring(e.ver) .. ')')
    if e.car then
        -- A car playing tasks (server/actors.lua).
        local lines = { ('~b~car (actor %d)~w~  owner: %s  version: %s  held frozen: %s'):format(e.id, owner, brain, yn(e.frozen)) }
        if (e.pinned or 0) ~= 0 then
            lines[#lines + 1] = ('take kept on: %s%s'):format(e.pinned == meSid and '~g~you~w~' or ('player ' .. tostring(e.pinned)),
                e.pinned == e.owner and '' or '  ~o~(not its owner yet)~w~')
        end
        if type(e.job) == 'table' then lines[#lines + 1] = jobLine(e.job) end
        return lines
    end
    local w = watches[e.net]
    local lines = {
        ('~b~NPC %d~w~  owner: %s  brain: %s'):format(e.id, owner, brain),
        ('frozen: %s  task: %s  alive: %s'):format(e.frozen and '~r~YES~w~' or 'no', tostring(e.task), yn(e.alive)),
        serverLine(e),
    }
    if type(e.job) == 'table' then lines[#lines + 1] = jobLine(e.job) end
    if type(e.sees) == 'string' then lines[#lines + 1] = '~p~sees~w~ ' .. e.sees end
    if w then
        lines[#lines + 1] = ('can move: %s  should be frozen: %s  fighting: %s  targets: %s'):format(
            w.canMove and 'yes' or '~r~NO~w~', yn(shouldFreeze(w)), yn(IsPedInCombat(ped, 0)), e.targets ~= '' and e.targets or 'none')
        if w.onCar then lines[#lines + 1] = '~g~riding a car~w~ (fixed to it: players can stand on it)' end
        if w.gate then
            local at = w.gateAt or w.post
            local iid = at and GetInteriorAtCoords(at.x, at.y, at.z + 1.0) or 0
            lines[#lines + 1] = ('~o~MLO hold: on~w~  ready: %s  interior there: %s  loaded: %s  floor: %s  at its post: %s'):format(
                yn(w.ready), iid ~= 0 and tostring(iid) or '~r~none~w~', yn(iid ~= 0 and IsInteriorReady(iid)), yn(floorAt(at)),
                yn(atPost(ped, w.post)))
        else
            lines[#lines + 1] = 'MLO hold: off'
        end
    else
        lines[#lines + 1] = (e.interior and '~o~MLO hold: on~w~  ' or '') .. 'this game does not run it'
    end
    return lines
end

local function drawLines(lines, x, y, z)
    SetDrawOrigin(x, y, z, 0)
    for i, line in ipairs(lines) do
        SetTextScale(0.0, 0.28)
        SetTextFont(4)
        SetTextProportional(true)
        SetTextColour(255, 255, 255, 230)
        SetTextOutline()
        SetTextCentre(true)
        SetTextEntry('STRING')
        AddTextComponentString(line)
        DrawText(0.0, -0.018 * (#lines - i + 1))
    end
    ClearDrawOrigin()
end

local function debugLoop()
    CreateThread(function()
        local printAt = 0
        while debugList do
            local now = GetGameTimer()
            local doPrint = now >= printAt
            for _, e in ipairs(debugList) do
                local ped = pedFor(e.net)
                local here
                local key = e.car and ('car' .. tostring(e.id)) or e.id   -- (NPC ids and car records are counted apart)
                if ped and not e.car and IsPedAPlayer(ped) then ped, here = nil, 'its id names a PLAYER in this game' end
                if ped then
                    local lines = debugLines(e, ped)
                    local c = GetEntityCoords(ped)
                    drawLines(lines, c.x, c.y, c.z + (e.car and 1.6 or 1.15))
                    if doPrint then
                        local flat = table.concat(lines, ' | '):gsub('~%a~', '')
                        if debugPrinted[key] ~= flat then
                            debugPrinted[key] = flat
                            print('[npcdebug] ' .. flat)
                        end
                    end
                elseif doPrint then
                    -- Near you on the server, but not in this game: nothing to draw on, so F8 only.
                    local flat = e.car
                        and ('car (actor %d, net %d, owner %s): NOT in this game'):format(e.id, e.net, e.owner == 0 and 'nobody' or tostring(e.owner))
                        or ('NPC %d (net %d, owner %s): %s | %s'):format(e.id, e.net, e.owner == 0 and 'nobody' or tostring(e.owner),
                            here or 'NOT in this game', serverLine(e)):gsub('~%a~', '')
                    if debugPrinted[key] ~= flat then
                        debugPrinted[key] = flat
                        print('[npcdebug] ' .. flat)
                    end
                end
            end
            if doPrint then printAt = now + 500 end
            Wait(0)
        end
    end)
end

RegisterNetEvent('whip_core:client:npcDebug', function(list)
    if list == false then
        debugList, debugPrinted = nil, {}
        return
    end
    if type(list) ~= 'table' then return end
    local wasOn = debugList ~= nil
    debugList = list
    if not wasOn then debugLoop() end
end)
