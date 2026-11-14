-- ============================================
-- NPCS — the NPC Creator (server)
-- ============================================
--
-- An NPC whip makes and looks after: a guard, a quest giver, a fence. The SERVER keeps the record
-- (who made it, what it should be doing, who it is hostile to) and makes the ped itself with
-- CreatePed, a networked MISSION ped kept for as long as whip wants it (orphan mode 2). The Director
-- uses this through the same functions the exports wrap, and so can any resource, from code.
--
-- WHO RUNS ITS AI. A networked ped is simulated by whichever player's game OWNS it, and that changes
-- as players come and go. What GTA keeps in that game's memory only (its relationship group, combat
-- and flee settings, whether it reacts, its task, its weapon) is LOST when the ped changes hands, and
-- a task sent before is never replayed. So the record holds the ped's BRAIN, and a slow tick (Every
-- 'npcs', a quarter second, idle at one second when there are none) sends it again:
--   * to every new owner (resent each second until that owner says it applied it),
--   * when who it should fight changes (a target goes down, gets up, leaves, comes online),
--   * when its task has ended while it is alive (GTA would let its own AI walk it off), at most every
--     2 s and 10 times a minute.
-- The owner applies it once and says so (whip_core:server:npcApplied, which only the ped's current
-- owner may send: the `ownerOf` schema key).
--
-- WHO IT FIGHTS: its hostile audience, plus anyone who attacked it in the last minute (fightBack),
-- never a player who is down. Two attackers do not make it swap back and forth: a new focus is taken
-- only when there is none, the focus is no longer a target, or it has been held for 5 s.
--
-- A guard has a range (opts.range, metres): its hostile audience counts only within that
-- distance of its post, and somebody who shot it is chased up to three times as far. Out of range they
-- are no target, so it goes back to its post. Without a range: wherever they are.
--
-- A group defends its own (opts.group, a name): hurt one, and every NPC of the same resource and group
-- takes the attacker as its attacker too.
--
-- INSIDE AN MLO (def.interior): a ped whose owning game has not got the interior falls through the
-- stock house (the Mirror Park loader brings homes in only within ~52 m). Every client is told which
-- NPCs are gated (whip_core:client:npcGates), so the game that newly owns one freezes it AT ONCE,
-- before the brain even arrives, until its own game has the interior.
--
-- HEALTH, DAMAGE, DEATH come from the server's own reads of the synced ped (health 0 until the owner's
-- game first sends it, so nothing counts before GetEntityMaxHealth > 0). The owner's game usually
-- sees a death first (whip_core:server:npcDied); the server then waits up to a second for its own
-- reading, so the killer is the server's word, never the owner's. A car's driver is its killer.
--
-- The record is checked against the entity every time (type, netId, model): server handles are reused,
-- so a record never acts on, or deletes, an entity that is no longer its ped.
--
-- REMOVING ONE never deletes it out from under the owner's game, which can send it straight back
-- (FiveM #3989/#2256): the owner is asked to delete it, and the server deletes it itself only when no
-- game holds it (and it is past its first second, while it is still being handed out), or after
-- three seconds (the HeldProps rule).
--
-- RUN TAGS. SpawnNpc(def, { tag = 'run:42' }) files the NPC under the caller's tag, so ReleaseTag
-- removes it with everything else the run made, and a released tag refuses new NPCs.
--
-- Events (types/events.lua): whip_core:npc:spawned, :despawned, :damaged, :killed. Core's own
-- reactions use Npcs.onLife(kind, fn), which runs before the public event; a hook must not wait.
--
-- Where it goes and what it does (the Director's NPC cards), all part of the brain, so a
-- new owner carries on with it:
--   post    moved (SetNpcState { post = coords }): it walks (pace 'walk') or runs ('run') there and
--           stands / guards from then on
--   follow  a player's server id: it walks after them; off (false), it stays where it is
--   flee    a player's server id: it runs from them, and fights nobody meanwhile
--   anim    { dict, clip } or { scenario }: what it does where it stands, instead of standing still
--   ride    { net, seat }: it sits in that car's seat (a take's driver and passengers), seated again by every
--           game that takes it over, and never knocked out
--   job     the step of its TASKS it is on (Npcs.runTasks; the Director's Tasks, server/director/tasks.lua), or
--           of its patrol (Npcs.setIdleTasks: IDLE TASKS, below)
--
-- TASKS. A list of steps (go to a point, play an emote, get in a car and drive off) rides in the brain
-- as its job: instant steps in a row go together with the step after them, as one job. The owner's game
-- runs it and says it applied it (the brain's own ack); a step that waits for something (got there, got
-- in) is done when the owner says so (whip_core:server:npcJob), or when it gives up. A timed step's
-- time starts at that ack, so a slow game loses none of it. A new owner gets the step again, with how
-- long it has run, and the lasting step before it (a wander under a Wait), and carries on; an instant
-- step is never run twice there (the teleport before a walk would put it back). While a job runs its
-- idle waits; with `fight` on, someone to fight ends the tasks and it fights. Its death ends them,
-- unless the list's own Die did it (a Revive can follow). Not applied within 5 s: said in the console.
--
-- IDLE TASKS (a guard's patrol: Npcs.setIdleTasks). A list it plays whenever nothing else has it: no tasks
-- of a card's, nobody to fight, not riding, following or running away. It starts from its step nearest the
-- NPC (the patrol point it is closest to), so a guard back from a fight, or from a card's tasks, carries on
-- its round from where it is. The same job and acks as tasks: every game that owns it walks the same round.
-- Moved to a new post (SetNpcState post), it patrols no more.
--
-- Not yet (plan section 6): NPCs that live across restarts, per-player NPCs, reactions to being aimed at.

Npcs = {}

local TICK_MS          = 250
local IDLE_MS          = 1000
local IDLE_RETRY_MS    = 10000    -- an idle list with nothing it can play now is tried again this long after
local CALM_MS          = 1000     -- a quiet NPC (isCalm: a shopkeeper) is looked at this often instead
local RESEND_MS        = 1000     -- a brain not yet applied is sent again this often
local RETASK_GAP_MS    = 2000     -- a ped that lost its task is re-tasked at most this often...
local RETASK_MAX       = 10       -- ...and this many times a minute
local TARGETS_GAP_MS   = 1000     -- a change of who it fights is sent at most this often
local FOCUS_HOLD_MS    = 5000     -- a focus is kept at least this long before another attacker takes it
local FORGIVE_MS       = 60000    -- an attacker stays a target this long after their last hit
local KILLER_WAIT_MS   = 1000     -- after the owner reports a death, how long to wait for the server's
local YOUNG_MS         = 1000     -- an unowned ped this young is still being handed out: never delete it then
local NO_OWNER_WARN_MS = 15000
local DEFAULT_CORPSE_MS = 60000
local LEASH_K          = 3        -- an attacker is chased this many times a guard's range from its post
local MAX_RANGE        = 500
local NO_TASK          = -2128726980   -- GetPedScriptTaskCommand once a ped's script task has ended
local BEHAVIOURS       = { stand = true, guard = true }

local recs     = {}    -- [npcId] = record, while it exists
local byEnt    = {}    -- [entity] = npcId
local retiring = {}    -- [entity] = { hash, netId } while its retire runs (CoreStop deletes these too)
local nextId   = 0
local madeAlone = {}   -- [owner] = true: told it made an NPC before any character loaded (Npcs.spawn)
local _lifeHooks = {}

-- ============================================
-- Small parts
-- ============================================

--- Core's own reaction to an NPC moment: runs before the public whip_core:npc:<kind> event. A hook
--- must not wait (it runs inside a registry removal and inside the Director's cards). 'revived' (up again: its tasks'
--- Revive) is core's alone, with no public event.
---@param kind string  'spawned' | 'despawned' | 'damaged' | 'killed' | 'revived'
---@param fn fun(payload: table)
function Npcs.onLife(kind, fn)
    local list = _lifeHooks[kind]
    if not list then list = {}; _lifeHooks[kind] = list end
    list[#list + 1] = fn
end

local function runHooks(kind, payload)
    for _, fn in ipairs(_lifeHooks[kind] or {}) do
        local ok, err = pcall(fn, payload)
        if not ok then print(('[whip_core:npcs] a "%s" hook errored: %s'):format(kind, tostring(err))) end
    end
end

local function announce(kind, payload)
    runHooks(kind, payload)
    WhipEmit('whip_core:npc:' .. kind, payload)
end

local function netOwnerOf(ent)
    local o = NetworkGetEntityOwner(ent)
    return (o and o > 0) and o or nil
end

local function unsigned(h) return (tonumber(h) or 0) % 0x100000000 end

--- The player behind a damage source: a player's ped, or the driver of a car that hit it.
local function playerOf(ent)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil end
    if GetEntityType(ent) == 2 then ent = GetPedInVehicleSeat(ent, -1) end
    if not ent or ent == 0 then return nil end
    for _, p in ipairs(GetPlayers()) do
        local s = tonumber(p)
        if GetPlayerPed(s) == ent then return s end
    end
    return nil
end

--- Is this still the record's ped? Server handles are reused.
local function isOurs(rec)
    local e = rec.ent
    return e ~= nil and DoesEntityExist(e) and GetEntityType(e) == 1
        and NetworkGetNetworkIdFromEntity(e) == rec.netId and unsigned(GetEntityModel(e)) == unsigned(rec.hash)
        and (not GetEntityOrphanMode or GetEntityOrphanMode(e) == 2)   -- older servers lack the read (vehicles.lua)
end

local finite = DirectorKit.finite

--- x, y, z, heading from a vector4/vector3, an {x, y, z, w|heading} table, or nil.
local function readCoords(c)
    if c == nil then return nil end
    local x, y, z, h
    local t = type(c)
    if t == 'vector4' or t == 'vector3' then
        x, y, z = c.x, c.y, c.z
        h = (t == 'vector4') and c.w or nil
    elseif t == 'table' then
        x, y, z = rawget(c, 'x'), rawget(c, 'y'), rawget(c, 'z')
        h = rawget(c, 'w') or rawget(c, 'heading') or rawget(c, 'h')
    end
    if not (finite(x) and finite(y) and finite(z)) then return nil end
    h = finite(h) and (h % 360.0) or 0.0
    return x + 0.0, y + 0.0, z + 0.0, h
end

--- A player who can be fought: online, loaded, and not down.
local function fightable(src)
    local p = Players and Players[src]
    return p ~= nil and p.charId ~= nil and not p.isDead
end

local function sortedKeys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- Where an MLO NPC's interior is looked for: the spot it was placed at (`def.gateAt`: a group's guards
--- stand on a ring round it, and a ring spot just outside the MLO's bounds would never find the
--- interior), else its post.
local function gateOf(rec)
    if rec.gate then return { x = rec.gate.x, y = rec.gate.y, z = rec.gate.z } end
    return { x = rec.x, y = rec.y, z = rec.z }
end

-- ============================================
-- Removing a ped (the owner deletes it; see the top of the file)
-- ============================================

local function stillPed(ent, hash, netId)
    return DoesEntityExist(ent) and GetEntityType(ent) == 1 and NetworkGetNetworkIdFromEntity(ent) == netId
        and unsigned(GetEntityModel(ent)) == unsigned(hash)
end

local function retireEntity(ent, hash, netId, born, tick)
    tick = tick or 0
    if not stillPed(ent, hash, netId) then retiring[ent] = nil return end   -- gone, or not our ped any more
    local owner = netOwnerOf(ent)
    if tick >= 12 or (not owner and GetGameTimer() - born >= YOUNG_MS) then
        DeleteEntity(ent)
        retiring[ent] = nil
        return
    end
    if owner and tick % 2 == 0 then
        TriggerClientEvent('whip_core:client:npcDelete', owner, netId, hash)
    end
    SetTimeout(250, function() retireEntity(ent, hash, netId, born, tick + 1) end)
end

--- An NPC is over: forget it, take the ped away, and say so. Never waits (a registry's onRemove).
local function retire(rec, why)
    if rec.gone then return end
    rec.gone = true
    recs[rec.id] = nil
    if rec.ent then byEnt[rec.ent] = nil end
    if rec.interior then TriggerClientEvent('whip_core:client:npcGateGone', -1, rec.netId) end
    if rec.ent and isOurs(rec) then
        retiring[rec.ent] = { hash = rec.hash, netId = rec.netId }
        retireEntity(rec.ent, rec.hash, rec.netId, rec.born)
    end
    -- Its tasks end with it (whoever started them hears so).
    local seq = rec.seq
    rec.seq, rec.job = nil, nil
    if seq and seq.onEnd then
        local ok, err = pcall(seq.onEnd, 'gone')
        if not ok then print(('[whip_core:npcs] NPC %d: its tasks\' end hook failed: %s'):format(rec.id, tostring(err))) end
    end
    announce('despawned', { npcId = rec.id, tag = rec.tag, owner = rec.owner, reason = rec.goneWhy or why })
end

-- Every NPC is a registration of the resource that made it, under '<resource>:<npcId>': swept when
-- that resource stops, removed by ReleaseTag with the rest of its run.
local reg = Registry.new('npc', {
    label = 'NPC',
    scoped = true,
    releaseOrder = 20,
    same = false,
    onRemove = function(_, rec, _, why) retire(rec, why) end,
})

-- ============================================
-- Who it fights, and the brain
-- ============================================

--- Is player `src` within `metres` of the NPC's post (the server's own reading of their ped)?
local function nearPost(rec, src, metres)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local c = GetEntityCoords(ped)
    if not c then return false end
    local dx, dy, dz = c.x - rec.x, c.y - rec.y, c.z - rec.z
    return dx * dx + dy * dy + dz * dz <= metres * metres
end

--- Its hostile audience (within its range, if it has one) plus recent attackers, none of them down;
--- the focus dropped when it no longer is one. An attacker who goes down, leaves, has not hit it for
--- a minute, or has run past its leash (three times its range) is forgiven.
local function targetsOf(rec, now)
    local set = Audience.sources(rec.hostileTo)
    if rec.range then
        for s in pairs(set) do if not nearPost(rec, s, rec.range) then set[s] = nil end end
    end
    for s, at in pairs(rec.attackers) do
        if now - at >= FORGIVE_MS or not fightable(s) or (rec.range and not nearPost(rec, s, rec.range * LEASH_K)) then
            rec.attackers[s] = nil
        else
            set[s] = true
        end
    end
    for s in pairs(set) do if not fightable(s) then set[s] = nil end end
    if rec.focus and not set[rec.focus] then rec.focus = nil end
    return sortedKeys(set)
end

local function pushBrain(rec, why)
    local owner = rec.ent and netOwnerOf(rec.ent)
    if not owner then return end
    local now = GetGameTimer()
    local targets = targetsOf(rec, now)
    rec.targetsKey = table.concat(targets, ',')
    rec.sentTo, rec.sentAt = owner, now
    TriggerClientEvent('whip_core:client:npcBrain', owner, rec.id, rec.netId, rec.ver, {
        behaviour = rec.behaviour,
        conditions = rec.conditions,
        weapon = rec.weapon,
        held = rec.held,          -- a Hold a Weapon step's choice, over its own gun ('' put away): TASK_HOOKS.started
        targets = targets,
        focus = rec.focus,
        alive = rec.alive,
        post = { x = rec.x, y = rec.y, z = rec.z, h = rec.h },   -- where it belongs: it goes back there
        gate = rec.interior,
        gateAt = rec.interior and gateOf(rec) or nil,             -- where its interior is looked for
        pace = rec.pace,
        follow = rec.follow,
        flee = rec.flee,
        anim = rec.anim,
        ride = rec.ride,
        frozen = rec.frozen,      -- its list ended on Freeze (on): held so, as a car is (server/actors.lua)
        attack = rec.attack,      -- what it attacks while it has nobody to fight: an NPC, a car, a place
        style = rec.style,        -- how it fights, every fight (NPC Attacks): as a Shoot At shoots (client/npcs.lua shooting)
        armour = rec.armourDue,   -- its armour at birth, until a game says it applied it
        outfit = rec.outfit,      -- what it wears (its owner puts it on: client/ped_outfit.lua)
        job = TaskSeq.wire(rec, now),   -- its tasks' step, with how long it has run (server/task_seq.lua)
    })
    rec.lastPush = why
end

local function bump(rec, why)
    rec.ver = rec.ver + 1
    rec.acked = 0
    rec.nextTickAt, rec.calm = nil, nil   -- changed: looked at on the next pass (see the tick)
    pushBrain(rec, why)
end

-- ============================================
-- Tasks (the header's TASKS)
-- ============================================

--- A dead NPC up again (its tasks' Revive, applied by its game): alive, and read afresh.
local function revived(rec)
    local wasDead = not rec.alive
    rec.alive = true
    rec.killedAt, rec.killer, rec.deadReportAt, rec.causeOfDeath = nil, nil, nil, nil
    rec.synced = false
    rec.oldDeathSrc = rec.ent and GetPedSourceOfDeath(rec.ent) or nil
    -- (What forgot it at its death has it again: a lore character's voice.)
    if wasDead then runHooks('revived', { npcId = rec.id, tag = rec.tag, owner = rec.owner, netId = rec.netId, lore = rec.lore }) end
end

local idleReady, startIdle   -- (below: its patrol, which the end of a list can go back to)

--- How an NPC plays its tasks (server/task_seq.lua): its brain carries the job, and its death matters.
local TASK_HOOKS = {
    bump = function(rec, why) bump(rec, why) end,
    alive = function(rec) return rec.alive end,
    name = function(rec) return ('NPC %d (%s)'):format(rec.id, rec.model) end,
    started = function(rec, list)
        for _, s in ipairs(list) do
            if s.t == 'revive' then revived(rec); rec.seq.selfDeath = false end
            -- What it holds is the NPC's, not its game's: kept here and sent with every brain (pushBrain's held), so a
            -- brain sent again, or a game taking it over, keeps the step's gun ('' put away).
            if s.t == 'weapon' and type(s.p) == 'table' and type(s.p.weapon) == 'string' then rec.held = s.p.weapon end
        end
    end,
    -- Done with "it stops" (or stopped with `stay`), it stays where it got to: that is its post now, so it
    -- does not walk back to where it was made (not after a look round: `keepPost`). Then its patrol again, if
    -- it has one and nothing else has it; else the brain without the job. (A list put in place of another,
    -- `rec.replacing`, is not the end of anything.)
    ended = function(rec, why, seq, stay)
        -- A list that ends frozen leaves it frozen (a car's does: server/actors.lua), till its next list says
        rec.frozen = (why == 'done' and seq.after ~= 'loop' and seq.frozen == true) or nil
        if not seq.keepPost and (stay or (why == 'done' and seq.after ~= 'loop')) and rec.ent and DoesEntityExist(rec.ent) then
            local c = GetEntityCoords(rec.ent)
            rec.x, rec.y, rec.z, rec.h = c.x, c.y, c.z, GetEntityHeading(rec.ent)
            rec.gate = nil
        end
        if seq.idle and why == 'done' and rec.idle then rec.idle.done = true end   -- a round walked once: over
        -- One with nothing it can play now (every step passed over: no player near it, say) is tried again a while
        -- later, not every second.
        if seq.idle and why == 'nothing to do' and rec.idle then rec.idle.retryAt = GetGameTimer() + IDLE_RETRY_MS end
        if rec.gone or rec.replacing then return end   -- (put in place of another: the new list's own push follows)
        if not seq.idle and idleReady(rec, GetGameTimer()) then
            startIdle(rec)
            return
        end
        bump(rec, 'tasks ' .. why)
    end,
}

local function endTasks(rec, why, stay) TaskSeq.finish(rec, why, TASK_HOOKS, stay) end

local function same(step) return step.p end   -- a patrol's steps point at nothing that moves: as they are

--- Does its patrol start now? It has one not yet walked to its end, and nothing else has it (frozen by the end of
--- its last list counts: it waits for the next).
function idleReady(rec, now)
    return rec.idle ~= nil and not rec.idle.done and now >= (rec.idle.retryAt or 0) and not rec.seq and rec.alive
        and not rec.frozen and not rec.ride and not rec.follow and not rec.flee and not rec.attack
        and #targetsOf(rec, now) == 0
end

--- Its patrol, from the Go To nearest where it is now (a floor above or below counts as further); a list that says
--- `fromTop`, from its first step the first time.
function startIdle(rec)
    local plan = rec.idle.plan
    local from, best = 1, nil
    local c = rec.ent and DoesEntityExist(rec.ent) and GetEntityCoords(rec.ent) or nil
    if rec.idle.fromTop and not rec.idle.begun then c = nil end
    rec.idle.begun = true
    if c then
        for i, s in ipairs(plan.steps) do
            local a = s.t == 'goTo' and type(s.p) == 'table' and s.p.at or nil
            if a then
                local dx, dy, dz = a.x - c.x, a.y - c.y, (a.z - c.z) * 2.0
                local d = dx * dx + dy * dy + dz * dz
                if not best or d < best then best, from = d, i end
            end
        end
    end
    TaskSeq.start(rec, plan, { resolve = rec.idle.resolve or same, from = from, idle = true }, TASK_HOOKS)
end

-- ============================================
-- Death
-- ============================================

local function markDead(rec)
    if not rec.alive then return end
    rec.alive = false
    rec.killedAt = GetGameTimer()
    local killerEnt = GetPedSourceOfDeath(rec.ent)
    if not killerEnt or killerEnt == 0 then killerEnt = GetPedSourceOfDamage(rec.ent) end
    rec.killer = playerOf(killerEnt)
    rec.causeOfDeath = GetPedCauseOfDeath(rec.ent)
    local c = GetEntityCoords(rec.ent)
    announce('killed', {
        npcId = rec.id, tag = rec.tag, owner = rec.owner,
        killer = rec.killer, weapon = rec.causeOfDeath,
        coords = { x = c.x, y = c.y, z = c.z },
    })
    -- Its tasks end with it, unless their own Die did it (a Revive may come next).
    if rec.seq and not rec.seq.selfDeath then endTasks(rec, 'died') end
end

-- ============================================
-- The tick (one for every NPC)
-- ============================================

--- Somebody hurt `rec`: it fights back, and so does every NPC of its group. The same focus rule for
--- each: a new focus only when it has none, its focus went, or it has had its turn (two attackers
--- trading hits must not make it swap targets every tick).
local function takeAttacker(rec, attacker, now)
    if not (rec.fightBack and rec.alive and fightable(attacker)) then return end
    -- Past its leash, a hit changes nothing: taken, it would be dropped again by the very push it
    -- caused, so every hit would push a brain and lose the focus.
    if rec.range and not nearPost(rec, attacker, rec.range * LEASH_K) then return end
    local isNew = rec.attackers[attacker] == nil
    rec.attackers[attacker] = now
    local focusOk = rec.focus ~= nil and fightable(rec.focus)
    if rec.focus ~= attacker and (not focusOk or (isNew and now - (rec.focusAt or 0) >= FOCUS_HOLD_MS)) then
        rec.focus, rec.focusAt = attacker, now
        bump(rec, 'fight back')
    elseif isNew then
        bump(rec, 'new attacker')    -- one more target, same focus
    end
end

local function tickOne(rec, now)
    if not isOurs(rec) then
        print(('[whip_core:npcs] NPC %d (%s) is gone from the world without whip removing it'):format(rec.id, rec.model))
        rec.goneWhy = 'lost'
        reg:remove(rec.owner, rec.id)   -- its own remove: onRemove retires it
        return
    end
    local ent = rec.ent

    local owner = netOwnerOf(ent)
    if owner ~= rec.netOwner then
        rec.netOwner = owner
        rec.acked = 0                      -- the new owner has applied nothing yet
        rec.synced = false                 -- and its health is read again from that game (below)
        if owner then pushBrain(rec, 'new owner') end
    elseif owner and rec.acked ~= rec.ver and now - (rec.sentAt or 0) >= RESEND_MS then
        pushBrain(rec, 'not applied yet')
    end
    if not owner and not rec.everOwned and now - rec.born >= NO_OWNER_WARN_MS and not rec.warned then
        rec.warned = true
        print(('[whip_core:npcs] NPC %d (%s) has had no owner for %d s: nobody near it, or the model does not exist')
            :format(rec.id, rec.model, NO_OWNER_WARN_MS // 1000))
    end
    if owner then rec.everOwned = true end

    -- Health: the server reads 0 until a game that owns the ped sends it, so it is read only while one
    -- does, from that game's first read above 0 (again after a change of owner). On Enhanced a ped's
    -- max health can come before its health, and that 0 made a living NPC dead (21 Oct 2026: "that NPC
    -- is dead" while it stood there). A death is still caught: the owner's game reports it (below).
    local hp = GetEntityHealth(ent)
    if owner and GetEntityMaxHealth(ent) > 0 and (rec.synced or hp > 0) then
        local ar = GetPedArmour(ent)
        if not rec.synced then
            rec.synced, rec.health, rec.armour = true, hp, ar
        elseif hp < rec.health or ar < rec.armour then
            local attacker = playerOf(GetPedSourceOfDamage(ent))
            local amount = (rec.health - hp) + math.max(0, rec.armour - ar)
            rec.health, rec.armour = hp, ar
            announce('damaged', { npcId = rec.id, tag = rec.tag, owner = rec.owner, amount = amount, health = hp,
                                  armour = ar, attacker = attacker, group = rec.group })
            if attacker then
                if hp > 0 then takeAttacker(rec, attacker, now) end
                -- Its group takes the attacker too (the same resource's NPCs of the same group), the
                -- one shot dead included: a guard killed outright is exactly when the rest should turn.
                if rec.group then
                    for _, other in pairs(recs) do
                        if other ~= rec and not other.gone and other.owner == rec.owner and other.group == rec.group then
                            takeAttacker(other, attacker, now)
                        end
                    end
                end
            end
        else
            rec.health, rec.armour = hp, ar
        end
        if rec.alive then
            -- (Revived by its tasks, its old killer may still read as the source of death: not a new one.)
            local deathEnt = GetPedSourceOfDeath(ent)
            if hp <= 0 or (deathEnt and deathEnt ~= 0 and deathEnt ~= rec.oldDeathSrc) then markDead(rec) end
        end
    end
    -- The owner's game said it died, and the killer had their time to show in the reads: dead, whatever
    -- the server reads of its health.
    if rec.alive and rec.deadReportAt and now - rec.deadReportAt >= KILLER_WAIT_MS then markDead(rec) end

    -- Who it should fight changed (someone went down, got up, left, came online): say so. Nobody left to
    -- fight, a patrol goes on at once (its job in the same brain: no walk home first).
    if rec.alive and rec.synced and owner and rec.acked == rec.ver and now - (rec.sentAt or 0) >= TARGETS_GAP_MS then
        local key = table.concat(targetsOf(rec, now), ',')
        if key ~= rec.targetsKey then
            if key == '' and idleReady(rec, now) then startIdle(rec) else bump(rec, 'targets changed') end
        end
    end

    -- Its tasks: the next step when this one is done. Somebody to fight ends them, when they say so.
    if rec.seq then
        if rec.seq.fight and rec.alive and rec.acked == rec.ver and (rec.targetsKey or '') ~= '' then
            endTasks(rec, 'fought')
        else
            TaskSeq.tick(rec, now, TASK_HOOKS)
        end
    end

    -- Its patrol, when nothing else has it (made, revived, a follow or a ride let go).
    if owner and rec.synced and rec.acked == rec.ver and idleReady(rec, now) then startIdle(rec) end

    -- Lost its task while alive: GTA would walk it off. Give the brain again (bounded). Not while its
    -- tasks run (a step that has finished on its game, it got there, waits for the next one there), nor while
    -- it rides (sitting in a car is no script task).
    if not rec.seq and not rec.ride and rec.alive and rec.synced and owner and rec.acked == rec.ver
        and GetPedScriptTaskCommand(ent) == NO_TASK
        and now - (rec.retaskAt or 0) >= RETASK_GAP_MS then
        -- The minute starts at its first re-task (from the clock's zero, a burst could straddle two).
        if not rec.retaskWindowAt or now - rec.retaskWindowAt >= 60000 then rec.retaskWindowAt, rec.retasks = now, 0 end
        if rec.retasks < RETASK_MAX then
            rec.retasks = rec.retasks + 1
            rec.retaskAt = now
            bump(rec, 'task lost')
        end
    end

    -- A body goes after its time.
    if not rec.alive and rec.corpseMs > 0 and now - rec.killedAt >= rec.corpseMs then
        rec.goneWhy = 'corpse'
        reg:remove(rec.owner, rec.id)
    end
end

--- Quiet: it cannot be hurt or move, and fights and follows nobody (a shopkeeper; a quest giver at
--- its post). Nothing its tick watches for can happen fast, so it is looked at every CALM_MS, not
--- every TICK_MS. Whatever changes it goes through bump, which pushes the brain at once and has it
--- looked at on the next pass.
local function isCalm(rec)
    local c = rec.conditions
    return rec.alive and c ~= nil and c.invincible == true and c.canMove == false
        and rec.hostileTo == nil and next(rec.attackers) == nil and rec.follow == nil and rec.flee == nil
        and rec.seq == nil and (rec.idle == nil or rec.idle.done)
end

Every('npcs', IDLE_MS, function()
    if next(recs) == nil then return IDLE_MS end
    local now = GetGameTimer()
    local due = {}
    for _, rec in pairs(recs) do
        if not rec.gone and now >= (rec.nextTickAt or 0) then due[#due + 1] = rec end
    end
    table.sort(due, function(a, b) return a.id < b.id end)
    for _, rec in ipairs(due) do
        if not rec.gone then
            local ok, err = pcall(tickOne, rec, now)
            if not ok then print(('[whip_core:npcs] NPC %d tick failed: %s'):format(rec.id, tostring(err))) end
            -- 50 ms early, so the pass that wakes CALM_MS from now finds it due. (The one bump a quiet
            -- NPC's own tick can make is a re-task, already pushed.)
            rec.calm = isCalm(rec)
            rec.nextTickAt = rec.calm and (now + CALM_MS - 50) or nil
        end
    end
    -- Only quiet ones: the loop itself wakes every CALM_MS.
    for _, rec in pairs(recs) do
        if not rec.gone and not rec.calm then return TICK_MS end
    end
    return CALM_MS
end)

-- ============================================
-- Interior NPCs: every client knows which ones are gated
-- ============================================

local function gateList()
    local out = {}
    for _, rec in pairs(recs) do
        if rec.interior then out[#out + 1] = { id = rec.id, netId = rec.netId, at = gateOf(rec) } end
    end
    return out
end

-- A character coming in hears of every gated NPC (core's own hook, not the public event).
Character.onLife('loaded', function(e)
    if e and e.source then TriggerClientEvent('whip_core:client:npcGates', e.source, gateList()) end
end)

-- ============================================
-- Making one
-- ============================================

local function readConditions(c, base)
    c = type(c) == 'table' and c or {}
    base = base or { invincible = false, canMove = true, reacts = false, flees = false }
    local out = {}
    for _, k in ipairs({ 'invincible', 'canMove', 'reacts', 'flees' }) do
        local v = rawget(c, k)
        if v == nil then out[k] = base[k] elseif type(v) == 'boolean' then out[k] = v else return nil, 'conditions.' .. k .. ' is true or false' end
    end
    return out
end

local function readWeapon(w)
    if w == nil or w == false then return nil end
    if type(w) == 'string' then w = { name = w } end
    if type(w) ~= 'table' or type(w.name) ~= 'string' or not w.name:upper():match('^WEAPON_[A-Z0-9_]+$') or #w.name > 64 then
        return false, 'weapon is a GTA weapon name, like WEAPON_PISTOL'
    end
    local ammo = math.tointeger(tonumber(w.ammo) or 250) or 250
    return { name = w.name:upper(), ammo = math.max(0, math.min(9999, ammo)) }
end

--- A LOOK made in the character editor: a freemode ped's face, hair, make-up, tattoos and clothes, as a player's
--- character has them, checked by the same rules (SanitizeAppearanceData). Its ped is the look's own model. Every game
--- that has the NPC puts it on its own copy (client/lore_reactions.lua: the face and the tattoos are not sent from one
--- game to another), asking for it by the NPC's id (whip_core:npcLook). nil for none; false and why when it is no look.
local MAX_LOOK = 10000   -- bytes of JSON, as a character's own save and a lore character's
local function readLook(l)
    if l == nil then return nil end
    if type(l) ~= 'table' or not SanitizeAppearanceData then return false, 'look is a look from the character editor' end
    local clean, why = SanitizeAppearanceData(l)
    if not clean then return false, 'look: ' .. tostring(why) end
    if #json.encode(clean) > MAX_LOOK then return false, ('look is %d bytes of JSON at most'):format(MAX_LOOK) end
    return clean
end

--- What it wears (client/ped_outfit.lua's flat table: c<part>d / c<part>t, p<prop>d / p<prop>t), only what that
--- takes; nil for none. Its owner puts it on (client/npcs.lua), checked against what its model has.
local OUTFIT_PROPS = { [0] = true, [1] = true, [2] = true, [6] = true, [7] = true }
local function readOutfit(o)
    if type(o) ~= 'table' then return nil end
    local out, any = {}, false
    for k, v in pairs(o) do
        local kind, i, which
        if type(k) == 'string' then kind, i, which = k:match('^([cp])(%d%d?)([dt])$') end
        local n = math.tointeger(tonumber(v))
        i = tonumber(i)
        if kind and n and ((kind == 'c' and i <= 11) or (kind == 'p' and OUTFIT_PROPS[i]))
            and n <= 999 and (n >= 0 or (n == -1 and kind == 'p' and which == 'd')) then
            out[k], any = n, true
        end
    end
    return any and out or nil
end

--- Who it fights: named people (server/audience.lua), never 'everyone'.
-- Never 'everyone'. Everyone but some (whoever is not a run's) is taken, and kept to its range (keptToRange below).
local function readAudience(a) return Audience.read(a, false, false, true) end

--- Everyone but some is fought only round its post: an NPC with that and no range would go for the whole server.
local function keptToRange(hostileTo, range)
    if Audience.isExcept(hostileTo) and not range then
        return false, 'an NPC that fights everyone but some needs a range (metres round its post)'
    end
    return true
end

--- A thing it attacks, not a player (the Director's NPC Attacks at a director entity): nil (unchanged), false (none),
--- { net = an NPC's or a car's netId } or { at = coords } (a prop: each game has its own copy, so where it stands; a
--- spot, a door...), or nil and why.
local function readAttack(v)
    if v == nil or v == false then return v end
    if type(v) ~= 'table' then return nil, 'attack is { net } or { at = coords } or false' end
    if v.net ~= nil then
        local net = Sanitize.id(v.net)
        if not net or net > 65535 then return nil, 'attack.net is a netId' end
        return { net = net }
    end
    local x, y, z = readCoords(v.at)
    if not x then return nil, 'attack.at must be a vector3 or { x, y, z }' end
    return { at = { x = x, y = y, z = z } }
end

--- How it fights (the Director's NPC Attacks), as a Shoot At task shoots (shared/director/steps.lua SHOOTING), for every
--- fight it has: nil (unchanged), false (as whip's NPCs fight), { accuracy = 0-100, rate = 10-100, pattern, skill },
--- or nil and why.
local PATTERNS = { ['single shots'] = true, ['bursts'] = true, ['full auto'] = true }
local SKILLS = { ['a rookie'] = true, ['a pro'] = true, ['a killer'] = true }
local function readStyle(v)
    if v == nil or v == false then return v end
    if type(v) ~= 'table' then return nil, 'style is { accuracy, rate, pattern, skill } or false' end
    local acc, rate = tonumber(v.accuracy), tonumber(v.rate)
    if not acc or acc < 0 or acc > 100 then return nil, 'style.accuracy is 0 to 100' end
    if not rate or rate < 10 or rate > 100 then return nil, 'style.rate is 10 to 100' end
    if not PATTERNS[v.pattern] then return nil, "style.pattern is 'single shots', 'bursts' or 'full auto'" end
    if not SKILLS[v.skill] then return nil, "style.skill is 'a rookie', 'a pro' or 'a killer'" end
    return { accuracy = math.floor(acc), rate = math.floor(rate), pattern = v.pattern, skill = v.skill }
end

--- A player it follows or runs from: nil (unchanged), false (none), a loaded player's server id, or
--- nil and why.
local function readPlayer(v, what)
    if v == nil or v == false then return v end
    local s = Sanitize.id(v)
    if not s or not (Players and Players[s] and Players[s].charId) then return nil, what .. ' is a loaded player\'s server id, or false' end
    return s
end

--- What it does where it stands: false (nothing), { dict, clip } or { scenario }, or nil and why.
local function readAnim(a)
    if a == false then return false end
    if type(a) ~= 'table' then return nil, 'anim is { dict, clip }, { scenario } or false' end
    if a.scenario ~= nil then
        if type(a.scenario) ~= 'string' or #a.scenario > 64 or not a.scenario:match('^[%w_]+$') then
            return nil, 'anim.scenario is a GTA scenario name, like WORLD_HUMAN_SMOKING'
        end
        return { scenario = a.scenario }
    end
    local function name(s) return type(s) == 'string' and #s > 0 and #s <= 128 and s:match('^[%w_@%-/%.]+$') ~= nil end
    if not (name(a.dict) and name(a.clip)) then return nil, 'anim is { dict, clip }: an animation dictionary and clip name' end
    return { dict = a.dict, clip = a.clip }
end

--- A guard's range: nil (none: wherever they are), a number of metres, or false and why.
local function readRange(r)
    if r == nil then return nil end
    local n = tonumber(r)
    if not finite(n) or n < 1 or n > MAX_RANGE then return false, ('range is 1-%d metres'):format(MAX_RANGE) end
    return n + 0.0
end

--- Make an NPC. Answers the npcId and the ped's netId, or false and why. Never waits.
---@param owner string   the calling resource (Registry.caller(), read before anything waits)
---@param def table      { model, coords, behaviour = 'stand'|'guard', conditions = { invincible, canMove, reacts, flees },
---                        weapon = 'WEAPON_X' | { name, ammo }, armour, interior, outfit (client/ped_outfit.lua's;
---                        not a lore character's, who wears their own look), look (an appearance from the character
---                        editor: its model is the ped's, and the outfit is not used; not a lore character's either),
---                        gateAt = coords (interior: where the MLO is looked for; default its coords) }
---@param opts table|nil { tag, hostileTo = audience, fightBack = true, corpseMs = 60000,
---                        range = metres (a guard: fights only near its post), group = 'name' (defend each other),
---                        bucket = routing bucket, set at birth (default 0, the shared world; the Director's
---                        test for a builder in a world of their own),
---                        because = what made it hostile, for Npcs.explain (setState's `because`) }
function Npcs.spawn(owner, def, opts)
    opts = type(opts) == 'table' and opts or {}
    if type(def) ~= 'table' then return false, 'an NPC needs a definition table' end
    -- A lore character's NPC (def.lore) wears their ped as it is now: a scenario keeps the one it was saved with,
    -- and the character's may have changed since (/whip, Director, Lore characters).
    local lore = type(def.lore) == 'string' and def.lore ~= '' and DirectorLore and DirectorLore.get(def.lore) or nil
    local model = lore and type(lore.model) == 'string' and lore.model ~= '' and lore.model or def.model
    -- Its own look (a lore character's NPC wears theirs instead): its ped is the look's.
    local look, lwhy = nil, nil
    if not (type(def.lore) == 'string' and def.lore ~= '') then
        look, lwhy = readLook(def.look)
        if look == false then return false, lwhy end
        if look then model = look.model end
    end
    if type(model) ~= 'string' or #model > 64 or not model:match('^[%w_]+$') then
        return false, 'model is a ped model name, like s_m_y_dealer_01'
    end
    local x, y, z, h = readCoords(def.coords)
    if not x then return false, 'coords must be a vector3/vector4 or { x, y, z, heading }' end
    -- (readCoords answers all four, or nil.)
    ---@cast y number
    ---@cast z number
    ---@cast h number
    local behaviour = def.behaviour or 'stand'
    if not BEHAVIOURS[behaviour] then return false, "behaviour is 'stand' or 'guard'" end
    local conditions, cwhy = readConditions(def.conditions)
    if not conditions then return false, cwhy end
    local weapon, wwhy = readWeapon(def.weapon)
    if weapon == false then return false, wwhy end
    local armour = math.tointeger(tonumber(def.armour) or 0) or 0
    armour = math.max(0, math.min(100, armour))
    local hostileTo, hwhy = readAudience(opts.hostileTo)
    if hostileTo == false then return false, hwhy end
    local corpseMs = tonumber(opts.corpseMs) or DEFAULT_CORPSE_MS
    if not finite(corpseMs) or corpseMs < 0 then corpseMs = DEFAULT_CORPSE_MS end
    local range, rwhy = readRange(opts.range)
    if range == false then return false, rwhy end
    local kept, kwhy = keptToRange(hostileTo, range)
    if not kept then return false, kwhy end
    local group = opts.group
    -- 128: room for the longest name the Director makes ('run:<id>:<worldId>', a world id up to 64).
    if group ~= nil and (type(group) ~= 'string' or group == '' or #group > 128) then
        return false, 'group is a name, up to 128 characters'
    end
    local tag = opts.tag
    local bucket = 0
    if opts.bucket ~= nil then
        local b = math.tointeger(tonumber(opts.bucket))
        if not b or b < 0 or b > 0x7fffffff then return false, 'bucket is a routing bucket, a whole number 0 or more' end
        bucket = b
    end
    local gx, gy, gz = readCoords(def.gateAt)

    nextId = nextId + 1
    local id = nextId
    local rec = {
        id = id, owner = owner, tag = tag, model = model, hash = GetHashKey(model),
        x = x, y = y, z = z, h = h, behaviour = behaviour, conditions = conditions, weapon = weapon,
        interior = def.interior == true, gate = gx and { x = gx, y = gy, z = gz } or nil,
        hostileTo = hostileTo, fightBack = opts.fightBack ~= false, attackers = {}, focus = nil,
        range = range, group = group,
        -- The Director's lore character it is (its world thing's def.lore), for lore voices (director/lore_voice.lua).
        lore = type(def.lore) == 'string' and def.lore ~= '' and def.lore:sub(1, 64) or nil,
        look = look,
        outfit = not lore and not look and readOutfit(def.outfit) or nil,
        corpseMs = corpseMs, alive = true, synced = false, ver = 1, acked = 0, retasks = 0,
        born = GetGameTimer(),
        -- What made it fight from birth (opts.because: the Director's Spawn NPC), for Npcs.explain.
        why = { hostileTo = hostileTo and (type(opts.because) == 'string' or type(opts.because) == 'table') and opts.because or nil },
    }
    -- The registration first: a closed run tag refuses the NPC before any ped exists.
    local ok, why = reg:add(owner, id, rec, tag and { tag = tag } or nil)
    if not ok then return false, why end

    -- Made with nobody in the game, on Enhanced its network id is handed out again later, to a player's
    -- ped or a car (Character.afterFirstLoad). Said once per resource that does it.
    if GamePlatform.enhanced and not Character.anyLoaded() and not madeAlone[owner] then
        madeAlone[owner] = true
        print(('^3[whip_core:npcs] %s made an NPC before any character loaded: on Enhanced its network id can go to a player or a car later. Make NPCs after whip_core:player:loaded.^7')
            :format(tostring(owner)))
    end

    local ent = CreatePed(4, rec.hash, x, y, z, h, true, true)
    if not ent or ent == 0 or not DoesEntityExist(ent) then
        rec.gone = true
        reg:remove(owner, id)
        return false, 'the ped could not be made (is the model right?)'
    end
    SetEntityOrphanMode(ent, 2)                -- KeepEntity: whip decides when it goes
    SetEntityRoutingBucket(ent, bucket)        -- at birth, before any game has it
    -- A safety hold until its owner's game has the brain. This is an RPC: Legacy queues it until the ped
    -- has an owner (so it can land AFTER that game let the ped go), and Enhanced may never deliver it.
    -- Either way the owner's watch puts the freeze back to what the brain says each quarter second
    -- (client/npcs.lua), so nothing depends on it.
    if not conditions.canMove or rec.interior then FreezeEntityPosition(ent, true) end
    -- No weapon and no armour here: an RPC to a ped nobody owns yet may never arrive on Enhanced, so both
    -- go in the brain. The gun goes AFTER telling the ped not to drop it (a gun given now and the ped
    -- killed before its brain arrives would leave a real, untracked weapon pickup); the armour is owed
    -- until a game says it applied it (armourDue), so a later owner never tops it up after a fight.
    rec.armourDue = armour > 0 and armour or nil

    rec.ent, rec.netId = ent, NetworkGetNetworkIdFromEntity(ent)
    recs[id] = rec
    byEnt[ent] = id
    if rec.interior then
        TriggerClientEvent('whip_core:client:npcGate', -1, id, rec.netId, gateOf(rec))
    end
    announce('spawned', { npcId = id, tag = tag, owner = owner, netId = rec.netId, model = model,
                          coords = { x = x, y = y, z = z }, lore = rec.lore, look = rec.look ~= nil or nil })
    return id, rec.netId
end

--- Remove one of the caller's NPCs.
function Npcs.despawn(owner, npcId)
    local id = Sanitize.id(npcId)
    if not id then return false, 'an npcId is a number' end
    local rec = recs[id]
    if not rec or rec.owner ~= owner then return false, 'no such NPC of yours' end
    return reg:remove(owner, id)
end

--- What anyone may know about an NPC: a copy.
local function view(rec)
    local ours = isOurs(rec)
    local c = ours and GetEntityCoords(rec.ent) or nil
    return {
        npcId = rec.id, owner = rec.owner, tag = rec.tag, model = rec.model, netId = rec.netId, lore = rec.lore,
        look = rec.look ~= nil or nil,   -- (it has one from the character editor: Npcs.lookOf)
        alive = rec.alive, health = rec.health, armour = rec.armour, behaviour = rec.behaviour,
        conditions = { invincible = rec.conditions.invincible, canMove = rec.conditions.canMove,
                       reacts = rec.conditions.reacts, flees = rec.conditions.flees },
        targets = targetsOf(rec, GetGameTimer()), focus = rec.focus, range = rec.range, group = rec.group,
        killer = rec.killer, killedAt = rec.killedAt, weapon = rec.causeOfDeath,
        coords = c and { x = c.x, y = c.y, z = c.z } or { x = rec.x, y = rec.y, z = rec.z },
        post = { x = rec.x, y = rec.y, z = rec.z, heading = rec.h }, pace = rec.pace or 'walk',
        follow = rec.follow, flee = rec.flee, interior = rec.interior == true,
        tasks = rec.seq and not rec.seq.idle and { i = rec.seq.i, n = #rec.seq.steps } or nil,
        patrols = rec.idle ~= nil and not rec.idle.done,   -- (a patrol, walking it now or once nothing else has it)
    }
end

function Npcs.get(npcId)
    local id = Sanitize.id(npcId)
    local rec = id and recs[id]
    if not rec then return nil end
    return view(rec)
end

--- Why a def.look cannot be an NPC's (Npcs.spawn would refuse it), or nil: for the Director's Check.
function Npcs.lookProblem(l)
    local ok, why = readLook(l)
    if ok == false then return why end
    return nil
end

--- Its look from the character editor (as kept: read it, never write it), or nil.
function Npcs.lookOf(npcId)
    local id = Sanitize.id(npcId)
    local rec = id and recs[id]
    return rec and rec.look or nil
end

--- { tag?, owner? }: a caller's tag is the caller's own (as ReleaseTag reads it).
function Npcs.list(filter)
    filter = type(filter) == 'table' and filter or {}
    local out = {}
    for _, rec in pairs(recs) do
        if (filter.owner == nil or rec.owner == filter.owner) and (filter.tag == nil or rec.tag == filter.tag) then
            out[#out + 1] = view(rec)
        end
    end
    table.sort(out, function(a, b) return a.npcId < b.npcId end)
    return out
end

--- 'netId' | 'entity' -> npcId, or false. Only while that is still the record's ped.
function Npcs.by(kind, v)
    local ent
    if kind == 'entity' then
        ent = v
    elseif kind == 'netId' then
        local n = Sanitize.id(v)
        if not n then return false end
        ent = NetworkGetEntityFromNetworkId(n)
    else
        return false
    end
    local id = ent and byEnt[ent]
    local rec = id and recs[id]
    if not rec or not isOurs(rec) then return false end
    return id
end

--- A seat it rides in: { net = a car's netId, seat = -1 (the driver's) .. 14 } | false (gets nothing: it is let go).
local function readRide(v)
    if v == false then return false end
    if type(v) ~= 'table' then return nil, 'ride is { net, seat } or false' end
    local net, seat = Sanitize.id(v.net), math.tointeger(tonumber(v.seat))
    if not net or net > 65535 or not seat or seat < -1 or seat > 14 then return nil, 'ride is { net = a car\'s netId, seat = -1 .. 14 }' end
    return { net = net, seat = seat }
end

--- Change what an NPC does: { behaviour, hostileTo = audience | false, fightBack, conditions = {...},
--- range = metres | false (none), post = coords (it goes there), interior = true | false (the new
--- post is inside an MLO), gateAt = coords (where that MLO is looked for: the spot a group gathers
--- round), pace = 'walk' | 'run', follow = serverId | false, flee = serverId | false,
--- anim = { dict, clip } | { scenario } | false, ride = { net, seat } | false,
--- attack = { net } | { at = coords } | false (an NPC it fights, a car or a place it shoots at, while it has nobody to fight),
--- style = { accuracy, rate, pattern, skill } | false (how it fights, every fight: readStyle) }.
--- `because` (optional): what set it, said by Npcs.explain: a card's title, or { text = 'spotted {who}', who = serverId }.
function Npcs.setState(owner, npcId, patch, because)
    local id = Sanitize.id(npcId)
    local rec = id and recs[id]
    if not rec or rec.owner ~= owner then return false, 'no such NPC of yours' end
    if type(patch) ~= 'table' then return false, 'a change is a table' end
    if patch.behaviour ~= nil and not BEHAVIOURS[patch.behaviour] then return false, "behaviour is 'stand' or 'guard'" end
    local conditions
    if patch.conditions ~= nil then
        local why
        conditions, why = readConditions(patch.conditions, rec.conditions)
        if not conditions then return false, why end
    end
    local hostileTo
    if patch.hostileTo ~= nil and patch.hostileTo ~= false then
        local why
        hostileTo, why = readAudience(patch.hostileTo)
        if not hostileTo then return false, why end
    end
    if patch.fightBack ~= nil and type(patch.fightBack) ~= 'boolean' then return false, 'fightBack is true or false' end
    local range
    if patch.range ~= nil and patch.range ~= false then
        local why
        range, why = readRange(patch.range)
        if not range then return false, why end
    end
    local px, py, pz, ph
    if patch.post ~= nil then
        px, py, pz, ph = readCoords(patch.post)
        if not px then return false, 'post must be a vector3/vector4 or { x, y, z, heading }' end
    end
    if patch.interior ~= nil and type(patch.interior) ~= 'boolean' then return false, 'interior is true or false' end
    local gx, gy, gz
    if patch.gateAt ~= nil then
        gx, gy, gz = readCoords(patch.gateAt)
        if not gx then return false, 'gateAt must be a vector3 or { x, y, z }' end
    end
    if patch.pace ~= nil and patch.pace ~= 'walk' and patch.pace ~= 'run' then return false, "pace is 'walk' or 'run'" end
    local follow, fwhy = readPlayer(patch.follow, 'follow')
    if fwhy then return false, fwhy end
    local flee, flwhy = readPlayer(patch.flee, 'flee')
    if flwhy then return false, flwhy end
    local anim
    if patch.anim ~= nil then
        local why
        anim, why = readAnim(patch.anim)
        if anim == nil then return false, why end
    end
    local ride
    if patch.ride ~= nil then
        local why
        ride, why = readRide(patch.ride)
        if ride == nil then return false, why end
    end
    local attack
    if patch.attack ~= nil then
        local why
        attack, why = readAttack(patch.attack)
        if attack == nil then return false, why end
    end
    local style
    if patch.style ~= nil then
        local why
        style, why = readStyle(patch.style)
        if style == nil then return false, why end
    end
    -- (Everyone but some, kept to a range: the one this asks for, or the one it has.)
    if hostileTo then
        local kept, why = keptToRange(hostileTo, patch.range == false and nil or range or rec.range)
        if not kept then return false, why end
    end

    local wasGated = rec.interior
    if px then
        rec.x, rec.y, rec.z, rec.h = px, py, pz, ph
        rec.gate = nil   -- the new post is where its interior is looked for, unless gateAt says
    end
    if gx then rec.gate = { x = gx, y = gy, z = gz } end
    if patch.interior ~= nil then rec.interior = patch.interior end
    -- Every game knows where a gated NPC stands (it freezes one it newly owns until the interior is
    -- there): a moved post, or one no longer inside, says so.
    if px or gx or patch.interior ~= nil then
        if rec.interior then
            TriggerClientEvent('whip_core:client:npcGate', -1, rec.id, rec.netId, gateOf(rec))
        elseif wasGated then
            TriggerClientEvent('whip_core:client:npcGateGone', -1, rec.netId)
        end
    end
    if patch.pace ~= nil then rec.pace = patch.pace end
    if follow ~= nil then rec.follow = follow or nil end
    if flee ~= nil then rec.flee = flee or nil end
    if anim ~= nil then rec.anim = anim or nil end
    if ride ~= nil then rec.ride = ride or nil end
    if attack ~= nil then rec.attack = attack or nil end
    if style ~= nil then rec.style = style or nil end
    if patch.behaviour ~= nil then rec.behaviour = patch.behaviour end
    if patch.range == false then rec.range = nil elseif range then rec.range = range end
    if conditions then rec.conditions = conditions end   -- the owner's game applies it (freezing too)
    if patch.hostileTo == false then
        rec.hostileTo, rec.attackers, rec.focus = nil, {}, nil   -- calm: it forgets who hit it, too
    elseif hostileTo then
        rec.hostileTo = hostileTo
    end
    if patch.fightBack ~= nil then rec.fightBack = patch.fightBack end
    -- What set each thing, for Npcs.explain (a thing switched off forgets it).
    if because ~= nil and type(because) ~= 'string' and type(because) ~= 'table' then because = nil end
    rec.why = rec.why or {}
    for _, k in ipairs({ 'hostileTo', 'attack', 'flee', 'follow', 'post', 'anim', 'ride' }) do
        if patch[k] == false then rec.why[k] = nil elseif patch[k] ~= nil then rec.why[k] = because end
    end
    -- Sent somewhere (a new post), it patrols no more; following, running away or riding, its patrol waits.
    if px and rec.idle then rec.idle.done = true end
    if rec.seq and rec.seq.idle and (px or rec.follow or rec.flee or rec.ride) then
        endTasks(rec, 'stopped')   -- (its own bump: the brain without the patrol)
        return true
    end
    bump(rec, 'changed')
    return true
end

--- Every NPC riding the car `netId` is let off (its ride goes: an Everyone Out, server/actors.lua). Its brain is
--- pushed again.
function Npcs.leaveRide(netId)
    for _, rec in pairs(recs) do
        if rec.ride and rec.ride.net == netId and not rec.gone then
            rec.ride = nil
            bump(rec, 'ride over')
        end
    end
end

--- Start an NPC's tasks (the header's TASKS), in place of any it was running (those end 'stopped').
---@param plan table   { steps = DirectorTasks.compile's steps, after = 'stop' | 'loop', fight = bool }
---@param opts table   { resolve = fn(step) -> params | nil, why (its targets, at the moment it starts),
---                      onEnd = fn(why), log = fn(text), from = step number (default 1) }
function Npcs.runTasks(owner, npcId, plan, opts)
    local id = Sanitize.id(npcId)
    local rec = id and recs[id]
    if not rec or rec.owner ~= owner or rec.gone then return false, 'no such NPC of yours' end
    if type(plan) ~= 'table' or type(plan.steps) ~= 'table' or #plan.steps == 0 then return false, 'no steps' end
    opts = type(opts) == 'table' and opts or {}
    if type(opts.resolve) ~= 'function' then return false, 'resolve is a function' end
    -- A rider (Play Take's, a card's Ride) given a list that gets it out or on its feet: the ride is over, or its
    -- watch would seat it again as the list ends, wherever it walked to. (Shooting or talking from the seat keeps it.)
    if rec.ride then
        for _, s in ipairs(plan.steps) do
            if DirectorSteps.is(s.t, 'endsRide') then rec.ride = nil break end
        end
    end
    -- The list it had ends without a push of its own (not the moment to go back to its patrol, either): the
    -- new one's first job is the one push. One with nothing to play pushes nothing, so the brain goes without.
    rec.replacing = true
    local before = rec.ver
    local ok, err = pcall(TaskSeq.start, rec, plan, { resolve = opts.resolve, onEnd = opts.onEnd, log = opts.log, from = opts.from },
                          TASK_HOOKS)
    rec.replacing = nil
    if rec.ver == before and not rec.gone then bump(rec, 'tasks') end
    if not ok then return false, tostring(err) end
    return true
end

--- Stop an NPC's tasks. `stay`: it stays where it got to (its post moves there); otherwise it goes back to
--- its idle where it was. Answers the step it would pick up again from (TaskSeq.resumeAt), or false. (Its patrol is
--- not tasks.)
function Npcs.stopTasks(owner, npcId, stay)
    local id = Sanitize.id(npcId)
    local rec = id and recs[id]
    if not rec or rec.owner ~= owner then return false, 'no such NPC of yours' end
    if not rec.seq or rec.seq.idle then return false, 'it has no tasks running' end
    local at = TaskSeq.resumeAt(rec)
    endTasks(rec, 'stopped', stay == true)
    return at
end

--- What an NPC does whenever nothing else has it (the header's IDLE TASKS): a patrol, played from its Go To
--- nearest the NPC each time it starts. false: none (it stands or guards, as its behaviour says).
---@param plan table|false  { steps = task steps (server/director/routes.lua makes a route's), after = 'loop' | 'stop',
---                          fight = false: it does not stop to fight }
---@param opts table|nil    { resolve = fn(step) -> params | nil, why (each step's targets as it starts; default: as
---                          they are), fromTop = true (the first time from its first step: a standing NPC's own list,
---                          server/director/nodes_tasks.lua) }
function Npcs.setIdleTasks(owner, npcId, plan, opts)
    local id = Sanitize.id(npcId)
    local rec = id and recs[id]
    if not rec or rec.owner ~= owner or rec.gone then return false, 'no such NPC of yours' end
    if plan ~= false and (type(plan) ~= 'table' or type(plan.steps) ~= 'table' or #plan.steps == 0) then
        return false, 'a patrol is { steps, after } or false'
    end
    opts = type(opts) == 'table' and opts or {}
    local running = rec.seq and rec.seq.idle
    rec.idle = plan and { plan = { steps = plan.steps, after = plan.after == 'stop' and 'stop' or 'loop', fight = plan.fight ~= false },
                          resolve = type(opts.resolve) == 'function' and opts.resolve or nil, fromTop = opts.fromTop == true } or nil
    rec.nextTickAt, rec.calm = nil, nil
    if running then endTasks(rec, 'stopped') end   -- the old round ends; the new one starts when it is idle
    return true
end

--- An NPC's tasks as they stand: { i = step, n = steps, laps, applied } while they run, or nil.
function Npcs.tasksOf(npcId)
    local id = Sanitize.id(npcId)
    local rec = id and recs[id]
    return rec and TaskSeq.state(rec) or nil
end

-- An NPC's look from the character editor, for any game that has it near (client/lore_reactions.lua puts it on):
-- { look, v } or {} for none (v: its id, as the looks list has it: director/lore_voice.lua). Nothing in it is
-- private: it is what everyone near sees.
SecureCallback('whip_core:npcLook', {
    -- (A burst for a group made at once, each NPC asked for by itself.)
    whileDead = true, rateLimit = 250, burst = 24,
    params = { { 'npcId', 'id' } },
}, function(_, _, npcId)
    local rec = recs[npcId]
    if not rec or not rec.look then return {} end
    return { look = rec.look, v = rec.id }
end)

-- ============================================
-- From the owning game
-- ============================================

-- Bursts are generous: one game can own many NPCs, and a refused ack is only resent a second later.
SecureEvent('whip_core:server:npcApplied', {
    rateLimit = 50, burst = 40, whileDead = true,
    params = { {'npcId', 'id'}, {'netId', 'id', 1, 65535}, {'ver', 'int', 0, 1000000} },
    ownerOf = 'netId',
}, function(_, _, npcId, netId, ver)
    local rec = recs[npcId]
    if not rec or rec.netId ~= netId then return end
    if ver == rec.ver then
        rec.acked = ver
        rec.armourDue = nil   -- that brain carried it, and it is on the ped now (pushBrain)
    end
end)

-- A task step that waits for something is done there (it got there, it got in): only for the job it is on.
SecureEvent('whip_core:server:npcJob', {
    rateLimit = 50, burst = 40, whileDead = true,
    params = { {'npcId', 'id'}, {'netId', 'id', 1, 65535}, {'jobId', 'int', 0, 2000000000}, {'how', 'enum', { 'done', 'failed' }} },
    ownerOf = 'netId',
}, function(_, _, npcId, netId, jobId, how)
    local rec = recs[npcId]
    if not rec or rec.netId ~= netId then return end
    TaskSeq.report(rec, jobId, how)
end)

SecureEvent('whip_core:server:npcDied', {
    rateLimit = 50, burst = 40, whileDead = true,
    params = { {'npcId', 'id'}, {'netId', 'id', 1, 65535} },
    ownerOf = 'netId',
}, function(_, _, npcId, netId)
    local rec = recs[npcId]
    if not rec or rec.netId ~= netId or not rec.alive then return end
    rec.deadReportAt = rec.deadReportAt or GetGameTimer()   -- the tick confirms it, with the killer
end)

-- ============================================
-- In words: what an NPC is doing, and why (the Director's NPC debug in a test)
-- ============================================
--
-- Two short lines from its record, in the order its brain decides (client/npcs.lua's task and idle): dead,
-- riding, running away, fighting, attacking a thing, playing its tasks or its patrol, following, walking to its
-- spot, standing there. WHY is what set it: the card that did (Npcs.setState's `because`), else what the record
-- knows (someone hit it, its hostile list, nothing else to do). What only its own game sees (GTA's own reaction,
-- with Reacts to danger on) that game says over it (client/director_npcdebug.lua).

local AWAY_M = 2.5   -- further than this from its post, with nothing else to do, it is walking back

--- Who a server id is: `name(src)` when given, else their character's name.
local function nameOf(src, name)
    if name then return name(src) end
    local p = Players and Players[src]
    return p and p.fullName or ('player ' .. tostring(src))
end

--- What set one thing (setState's `because`): its text, a {who} in it named.
local function becauseOf(rec, key, name)
    local b = rec.why and rec.why[key]
    if type(b) == 'table' then return (tostring(b.text):gsub('{who}', b.who and nameOf(b.who, name) or 'someone')) end
    return b
end

--- A task step's name, as its card's page has it ('Go To (run)').
local function stepName(step)
    local d = DirectorTasks and DirectorTasks.get(step.t)
    local label = d and d.label or tostring(step.t)
    local p = type(step.p) == 'table' and step.p or {}
    if step.t == 'goTo' and p.pace then label = ('%s (%s)'):format(label, p.pace) end
    if step.t == 'emote' and type(p.emote) == 'string' and p.emote ~= '' then label = ('%s: %s'):format(label, p.emote) end
    return label
end

--- What an NPC is doing and why: { what, why, state, step = { t, p } (its task step), reacts }, or nil.
--- state: 'dead' | 'riding' | 'fleeing' | 'fighting' | 'attacking' | 'tasks' | 'patrol' | 'following' | 'walking' | 'idle'.
---@param name function|nil  name(serverId) -> how to say who that is ("you" for the one reading it)
function Npcs.explain(npcId, name)
    local id = Sanitize.id(npcId)
    local rec = id and recs[id]
    if not rec then return nil end
    local now = GetGameTimer()
    local out = { reacts = rec.conditions.reacts == true }
    local function say(state, what, why) out.state, out.what, out.why = state, what, why return out end
    local seq = rec.seq
    if not rec.alive then
        if seq and seq.selfDeath then return say('dead', 'Dead', 'its own Die task') end
        return say('dead', 'Dead', rec.killer and ('killed by ' .. nameOf(rec.killer, name)) or 'killed')
    end
    if rec.ride then
        return say('riding', rec.ride.seat == -1 and 'Driving a car' or 'Sitting in a car', becauseOf(rec, 'ride', name) or 'its seat in a car')
    end
    if rec.flee then
        return say('fleeing', 'Running from ' .. nameOf(rec.flee, name), becauseOf(rec, 'flee', name) or 'told to run')
    end
    -- (A list started with "fight" off plays on whoever is there; its patrol always gives way to a fight.)
    local fights = not (seq and not seq.idle and seq.fight == false)
    local targets = fights and targetsOf(rec, now) or {}
    if #targets > 0 then
        local who = rec.focus and fightable(rec.focus) and rec.focus or targets[1]
        local what = 'Fighting ' .. nameOf(who, name) .. (#targets > 1 and (' and %d more'):format(#targets - 1) or '')
        if rec.attackers[who] then return say('fighting', what, nameOf(who, name) .. ' attacked it') end
        return say('fighting', what, becauseOf(rec, 'hostileTo', name) or 'it is set to fight them')
    end
    if rec.attack then
        local ent = rec.attack.net and NetworkGetEntityFromNetworkId(rec.attack.net) or 0
        local what = not rec.attack.net and 'Shooting at a place'
            or (ent ~= 0 and GetEntityType(ent) == 1 and 'Fighting an NPC') or 'Shooting at a car'
        return say('attacking', what, becauseOf(rec, 'attack', name) or 'told to attack it')
    end
    local step = seq and seq.steps and seq.steps[seq.i]
    if step then
        out.step = { t = step.t, p = step.p }
        local waiting = seq.started == nil and ' (its game has not started it yet)' or ''
        if seq.idle then
            return say('patrol', ('Following its route: %s, %d of %d'):format(stepName(step), seq.i, #seq.steps), 'its patrol' .. waiting)
        end
        if DirectorSteps.waitsOnCard(step.t, step.p) then
            return say('tasks', ('Task %d of %d: waiting for a card'):format(seq.i, #seq.steps), 'its tasks' .. waiting)
        end
        return say('tasks', ('Task %d of %d: %s'):format(seq.i, #seq.steps, stepName(step)), (becauseOf(rec, 'tasks', name) or 'its tasks') .. waiting)
    end
    if rec.follow then
        return say('following', 'Following ' .. nameOf(rec.follow, name), becauseOf(rec, 'follow', name) or 'told to follow')
    end
    if rec.conditions.canMove and isOurs(rec) then
        local c = GetEntityCoords(rec.ent)
        local dx, dy = c.x - rec.x, c.y - rec.y
        if dx * dx + dy * dy > AWAY_M * AWAY_M then
            return say('walking', 'Walking to its spot', becauseOf(rec, 'post', name) or 'back where it belongs')
        end
    end
    local still = not rec.conditions.canMove and ' (it cannot move)' or ''
    if rec.anim then return say('idle', 'Playing its animation', (becauseOf(rec, 'anim', name) or 'its animation at its spot') .. still) end
    if rec.behaviour == 'guard' then return say('idle', 'Guarding its spot', 'nothing else to do' .. still) end
    return say('idle', 'Standing at its spot', 'nothing else to do' .. still)
end

-- ============================================
-- /npcdebug: the server's view of each NPC near a dev (whip.devtools), for their overlay
-- ============================================
--
-- While it is on for someone, once a second they are sent,
-- for every NPC within 80 m of them, what only the server knows: who owns it, whether that owner has
-- said it applied the latest brain, whether the server reads it frozen, its script task. Their own
-- game adds what it knows (client/npcs.lua). Off, nothing is sent.

local debuggers = {}   -- [source] = true
local DEBUG_RANGE = 80.0
local TASK_NAMES = { [unsigned(NO_TASK)] = 'none' }
for _, n in ipairs({ 'SCRIPT_TASK_COMBAT', 'SCRIPT_TASK_STAND_STILL', 'SCRIPT_TASK_GUARD_CURRENT_POSITION',
                     'SCRIPT_TASK_FOLLOW_NAV_MESH_TO_COORD', 'SCRIPT_TASK_SMART_FLEE_PED', 'SCRIPT_TASK_FOLLOW_TO_OFFSET_OF_ENTITY',
                     'SCRIPT_TASK_PLAY_ANIM', 'SCRIPT_TASK_START_SCENARIO_IN_PLACE' }) do
    TASK_NAMES[unsigned(GetHashKey(n))] = n:gsub('^SCRIPT_TASK_', ''):lower()   -- a name the hash does not match shows as its number
end

local debugLooping = false
local function debugTick()
    if next(debuggers) == nil then debugLooping = false return end
    for src in pairs(debuggers) do
        local ped = GetPlayerPed(src)
        if not DevTools.isAllowed(src) then
            -- Developer mode off, or dev tools gone: the overlay goes with them.
            Npcs.debugFor(src, false)
        elseif not ped or ped == 0 then
            debuggers[src] = nil
        else
            local me = GetEntityCoords(ped)
            local list = {}
            -- Every NPC near the dev, its post when its ped is gone: what the server knows of it is the
            -- point (Enhanced, 21 Oct 2026: NPCs that vanished, or read as dead while standing).
            for _, rec in pairs(recs) do
                local exists = rec.ent ~= nil and DoesEntityExist(rec.ent)
                local c = exists and GetEntityCoords(rec.ent) or vector3(rec.x, rec.y, rec.z)
                local dx, dy, dz = c.x - me.x, c.y - me.y, c.z - me.z
                if dx * dx + dy * dy + dz * dz <= DEBUG_RANGE * DEBUG_RANGE then
                    local e = { id = rec.id, net = rec.netId, owner = 0, ver = rec.ver, acked = rec.acked, alive = rec.alive,
                                interior = rec.interior, targets = rec.targetsKey or '', exists = exists, ours = false,
                                synced = rec.synced == true }
                    e.job = TaskSeq.view(rec, GetGameTimer())   -- its tasks: the step, applied or not, for how long
                    -- What it sees (server/vision.lua): its cone, and each player's meter.
                    local v = Vision and Vision.of(rec.id)
                    if v then
                        local parts = {}
                        for s, m in pairs(v.meters) do
                            parts[#parts + 1] = ('%d %d%%%s'):format(s, math.floor(m * 100 + 0.5), v.spotted[s] and ' SPOTTED' or '')
                        end
                        table.sort(parts)
                        e.sees = ('%d m, %d deg%s: %s'):format(math.floor(v.range), math.floor(v.cone), v.state and (', ' .. v.state) or '',
                            #parts > 0 and table.concat(parts, ', ') or 'nobody')
                    end
                    if exists then
                        local task = unsigned(GetPedScriptTaskCommand(rec.ent))
                        e.ours = isOurs(rec) == true
                        e.owner = netOwnerOf(rec.ent) or 0
                        e.frozen = IsEntityPositionFrozen(rec.ent) == true
                        e.task = TASK_NAMES[task] or tostring(task)
                        e.idOk = NetworkGetEntityFromNetworkId(rec.netId) == rec.ent   -- its id still leads to it
                        e.hp, e.maxHp = GetEntityHealth(rec.ent), GetEntityMaxHealth(rec.ent)
                        e.orphan = GetEntityOrphanMode and GetEntityOrphanMode(rec.ent) or nil
                        e.bucket = GetEntityRoutingBucket(rec.ent)
                    end
                    list[#list + 1] = e
                end
            end
            -- And the cars playing tasks near them (server/actors.lua), drawn the same way.
            for _, a in ipairs(Actors and Actors.near(me, DEBUG_RANGE) or {}) do
                a.car = true
                list[#list + 1] = a
            end
            TriggerClientEvent('whip_core:client:npcDebug', src, list)
        end
    end
    SetTimeout(1000, debugTick)
end

--- Turn a dev's NPC overlay on or off.
function Npcs.debugFor(src, on)
    debuggers[src] = on and true or nil
    TriggerClientEvent('whip_core:client:npcDebug', src, on and {} or false)
    if on and not debugLooping then
        debugLooping = true
        SetTimeout(0, debugTick)
    end
end

RegisterCommand('npcdebug', function(src)
    if src == 0 then return end
    if not DevTools.isAllowed(src) then
        if DevTools.isEligible(src) then DevTools.sayOff(src) end
        return
    end
    Npcs.debugFor(src, not debuggers[src])
end, false)

AddEventHandler('playerDropped', function() debuggers[source] = nil end)

-- ============================================
-- whip_core stopping, and starting again
-- ============================================

--- No timers run after this, so no retiring: each owner is told and the server deletes too,
--- including a ped still part-way through its retire.
CoreStop.add(15, 'npcs: delete', function()
    local function drop(ent, hash, netId)
        if not stillPed(ent, hash, netId) then return end
        local owner = netOwnerOf(ent)
        if owner then TriggerClientEvent('whip_core:client:npcDelete', owner, netId, hash) end
        DeleteEntity(ent)
    end
    for _, rec in pairs(recs) do
        if rec.ent then drop(rec.ent, rec.hash, rec.netId) end
        rec.gone = true
    end
    for ent, r in pairs(retiring) do drop(ent, r.hash, r.netId) end
    recs, byEnt, retiring = {}, {}, {}
end)

--- Peds a previous whip_core left behind: whip made them (script whip_core, a MISSION ped) but holds
--- no record of them now. A ped an owner's game sent back after a delete comes back as a new entity
--- with the default orphan mode, so 0 counts as well as 2. No other whip_core code makes a networked
--- ped. GetEntityScript walks every resource, so this runs once, a few seconds after start.
SetTimeout(5000, function()
    local n = 0
    for _, ped in ipairs(GetAllPeds()) do
        local orphan = GetEntityOrphanMode and GetEntityOrphanMode(ped) or 2
        if not byEnt[ped] and not retiring[ped] and not IsPedAPlayer(ped) and GetEntityPopulationType(ped) == 7
            and (orphan == 2 or orphan == 0) and GetEntityScript(ped) == GetCurrentResourceName() then
            DeleteEntity(ped)
            n = n + 1
        end
    end
    if n > 0 then print(('[whip_core:npcs] removed %d NPC(s) a previous whip_core left behind'):format(n)) end
end)

-- ============================================
-- Exports
-- ============================================

--- Make an NPC: SpawnNpc(def, opts) -> npcId, netId | false, why.
exports('SpawnNpc', function(def, opts)
    local owner = Registry.caller()
    return Npcs.spawn(owner, def, opts)
end)

--- Remove one of your NPCs: DespawnNpc(npcId) -> true | false, why.
exports('DespawnNpc', function(npcId)
    local owner = Registry.caller()
    return Npcs.despawn(owner, npcId)
end)

--- Change what one of your NPCs does: SetNpcState(npcId, patch) -> true | false, why.
exports('SetNpcState', function(npcId, patch)
    local owner = Registry.caller()
    return Npcs.setState(owner, npcId, patch)
end)

--- An NPC, as a copy: GetNpc(ref) -> table | nil. `ref` is an npcId, `{ id = }`, or what you hold: `{ entity = }`
--- or `{ netId = }`, found only while that is still the NPC's ped.
exports('GetNpc', function(ref)
    if type(ref) == 'table' then
        if ref.id ~= nil then return Npcs.get(ref.id) end
        local kind = (ref.entity ~= nil and 'entity') or (ref.netId ~= nil and 'netId') or nil
        local npcId = kind and Npcs.by(kind, ref[kind])
        if not npcId then return nil end
        return Npcs.get(npcId)
    end
    return Npcs.get(ref)
end)

--- Your NPCs (or those under one of your tags): GetNpcs({ tag }) -> table[].
exports('GetNpcs', function(filter)
    local owner = Registry.caller()
    local f = { owner = owner }
    if type(filter) == 'table' and type(filter.tag) == 'string' then f.tag = filter.tag end
    return Npcs.list(f)
end)

