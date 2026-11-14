-- Director start-up wiring: connects the engine (runtime.lua, graph.lua, nodes*.lua) to whip.
--   * The scheduler is one Every loop: DirectorRuntime.pass() answers how long to sleep.
--   * The bridges carry whip's moments (NPC killed, item received, zone entered, point pressed, conversation
--     answered) to waiting cards. Anyone can fire the public events, so a card that pays out checks the truth first.
--   * An active scenario has a standing layer (what exists before anyone plays) under its own tag.
--   * A run's end releases everything made under its tag (run:<id>), deletes the ground items it placed and gives
--     the start point back to everyone.

-- (Director itself, with its active scenarios and isolated builders, is core.lua's: made before every Director file.)
local R = DirectorRuntime
local CORE = GetCurrentResourceName()
local serial = 0
local LAST_RUN_KVP = 'director:lastRunId'
local TESTING = 'a builder is testing it: stop the test first'

local function say(fmt, ...) print(('[whip_core:director] ' .. fmt):format(...)) end

-- ============================================
-- What the Director tells everyone (the Director API)
-- ============================================
--
-- Two audiences. whip_core's own reactions are HOOKS (Director.onLife), run at once (house rule:
-- core never reacts to its own public event). Other resources hear the PUBLIC EVENTS, whip_core:run:*
-- and whip_core:scenario:*, which go out AFTER THE SCHEDULER PASS: WhipEmit is a TriggerEvent, which
-- runs every listener there and then, and another resource's code must never run inside the pass (or
-- reach back into a run half way through a card). While whip_core stops there is no later tick, so
-- they go at once.
--
-- A test run is private: it announces nothing (a police script must not page its officers every time
-- a builder presses Test).

local lifeHooks = {}   -- [kind] = { fn, ... }

--- Hear one of the Director's moments, inside whip_core: 'run:started', 'run:ended',
--- 'run:playerLeft', 'scenario:switchedOn', 'scenario:switchedOff'. fn(payload) runs at once; test
--- runs included (payload.run.test says so).
function Director.onLife(kind, fn)
    lifeHooks[kind] = lifeHooks[kind] or {}
    table.insert(lifeHooks[kind], fn)
end

local outbox, sending = {}, false

local function sendOut()
    sending = false
    local list = outbox
    outbox = {}
    for _, e in ipairs(list) do
        local ok, err = pcall(WhipEmit, e[1], e[2])
        if not ok then say('^1the %s event failed: %s^0', e[1], tostring(err)) end
    end
end

--- Tell whip_core's hooks now, and other resources after the pass (`private`: a test run, nobody else).
---@param kind string  'run:started' ... (the public event is whip_core:<kind>)
---@param payload table  plain data only: it is copied to every listener
---@param private boolean|nil
function Director.announce(kind, payload, private)
    for _, fn in ipairs(lifeHooks[kind] or {}) do
        local ok, err = pcall(fn, payload)
        if not ok then say('^1a %s hook failed: %s^0', kind, tostring(err)) end
    end
    if private then return end
    outbox[#outbox + 1] = { 'whip_core:' .. kind, payload }
    if CoreStop and CoreStop.running then
        sendOut()
    elseif not sending then
        sending = true
        SetTimeout(0, sendOut)
    end
end

--- How a run ended, in the API's words: a Call Off card's quiet end is 'calledOff', any other stop
--- (an admin, whip_core stopping, the last player leaving) 'aborted'.
---@return string  'succeeded' | 'failed' | 'calledOff' | 'aborted' | 'faulted'
function Director.publicOutcome(run, outcome)
    if outcome == 'aborted' and run.quiet then return 'calledOff' end
    return outcome
end

-- ============================================
-- The scheduler
-- ============================================

local function pass()
    local ok, res = pcall(R.pass)
    if not ok then say('^1the scheduler pass failed: %s^0', tostring(res)) return 1000 end
    return res
end

-- The loop below sleeps on its last pass's answer. A pass in between (a run woken: a start, an answer
-- from outside) can find work due sooner than that: more queued, a Wait of 0.3 s. It asks for one more
-- pass then itself, until the loop's own comes first (otherwise that Wait would run up to 1 s late).
local loopDue = GetGameTimer() + 1000   -- when the loop's next pass comes (Every's first wait)
local function loopPass()
    local ms = pass()
    loopDue = GetGameTimer() + ms
    return ms
end
local function wokenPass()
    local ms = pass()
    if GetGameTimer() + ms < loopDue then SetTimeout(ms, wokenPass) end
end

R.setPorts({
    wake = function() SetTimeout(0, wokenPass) end,
    onEnd = function(run, outcome, reason) Director.runEnded(run, outcome, reason) end,
    -- A Fail Condition's rule broken (nodes_conditions.lua): the run's history says so, and a player taken out is told.
    broken = function(run, nodeId, src, reason, onlyThem)
        if onlyThem then
            Director.event(run, nodeId, 'out (fail condition)', src, reason)
            if not run.test then NotifyPlayer(src, reason, 'error') end
        else
            Director.event(run, nodeId, 'failed the run (fail condition)', src, reason)
        end
    end,
    takeOut = function(run, src, why) Director.takeOut(run, src, why) end,
})

Every('director', 1000, loopPass)

-- ============================================
-- Bridges: whip's moments, to the cards waiting for them
-- ============================================

R.bridge('npc.killed')
-- 'npc.down' is killed OR gone without dying (lost, removed): what "all of them are down" listens to.
R.bridge('npc.down')
Npcs.onLife('killed', function(p) R.emit('npc.killed', p) R.emit('npc.down', p) end)
Npcs.onLife('despawned', function(p) R.emit('npc.down', p) end)

R.bridge('npc.damaged')
Npcs.onLife('damaged', function(p) R.emit('npc.damaged', p) end)

-- From the server's seat record (core's own hook, not the event, which any resource can fire).
R.bridge('vehicle.entered')
Vehicles.onLife('entered', function(e)
    if type(e) == 'table' then R.emit('vehicle.entered', e) end
end)

-- A run's car CLAIMED (vehicle_claim.lua: a new car, a new id): every run's handle on the old one
-- follows it at once, so a card watching it (Car Delivered) sees the same car, not a lost one. Claim
-- Car remembers it as well, when its call comes back.
Vehicles.onLife('claimed', function(e)
    if type(e) ~= 'table' or not e.from or not e.vehicleId then return end
    for _, run in ipairs(R.list()) do
        for wid, h in pairs(run.world or {}) do
            if type(h) == 'table' and h.vehicleId == e.from then
                local ent = Vehicles.getEntity(e.vehicleId)
                run.world[wid] = { vehicleId = e.vehicleId, netId = ent and NetworkGetNetworkIdFromEntity(ent) or nil, claimed = true }
            end
        end
    end
end)

-- One of a run's players down (Player Downed): whip's own event, checked against the record there.
R.bridge('player.died')
AddEventHandler('whip_core:player:died', function(e)
    if type(e) == 'table' then R.emit('player.died', e) end
end)

R.bridge('item.added')
AddEventHandler('whip_core:item:added', function(e)
    if type(e) == 'table' then R.emit('item.added', e) end
end)


-- Weapons added or gone: a scenario that waits for one (brought back at a boot before its resource added it) is tried
-- again, as for cards (cards_api.lua).
WeaponCatalog.onChange(function() Director.catalogueChanged() end)

R.bridge('point.used')
R.bridge('conversation.choice')
R.bridge('conversation.ended')

-- A stash opened on someone's screen, from core's own hook (Containers.onLife), not the public event.
R.bridge('container.opened')
Containers.onLife('opened', function(p)
    if type(p) == 'table' then R.emit('container.opened', p) end
end)

-- Another resource telling runs something (SendDirectorEvent, api.lua): Wait for Script Event hears it.
R.bridge('script.event')

-- ============================================
-- What a run holds of the world
-- ============================================

--- What a card made (or the standing layer made) for a placed thing: { npcId, netId } for an NPC.
---@param run table
---@param worldId string
---@return table|nil
function Director.handleOf(run, worldId)
    local h = run.world[worldId]
    if h ~= nil then return h end
    local sc = run.scenario
    return sc and sc.standing[worldId] or nil
end

--- Who a card is acting for: the player the trigger carries, or the run's starter, while they are
--- still in it (a starter who left must not be answered: their server id may be someone else's next).
function Director.playerOf(ctx)
    local t = ctx.trigger
    local src = type(t) == 'table' and (t.source or (type(t.from) == 'table' and t.from.source)) or nil
    if src and ctx:isPlayer(src) then return src end
    local starter = ctx.run.starter
    if starter and ctx:isPlayer(starter) then return starter end
    return nil
end

--- The run's players' characters, for an access list (who may press a door, open a container).
---@param run table
---@return number[]
function Director.charIdsOf(run)
    local out = {}
    for s in pairs(run.players) do
        local cid = (run.charOf and run.charOf[s]) or (Players[s] and Players[s].charId)
        if cid then out[#out + 1] = cid end
    end
    table.sort(out)
    return out
end

--- The reason every create and destroy in a run writes to the activity log.
function Director.reason(run)
    return ('director:%s@%s run %d%s'):format(tostring(run.scenarioId), tostring(run.rev), run.id, run.test and ' test' or '')
end

-- (The conversations a card has with a player, its Talk points and talk marks: DirectorTalk, talk.lua.)

-- ============================================
-- Player flags, as a run sees them (server/player_flags.lua)
-- ============================================
--
-- A test leaves no flag behind (Test mode changes nothing that lasts): what a test sets is kept on the
-- test run, which reads it back over the player's real flags, and goes with it.

---@return any
function Director.flag(run, src, name)
    local over = run.test and run.testFlags and run.testFlags[src]
    if over and over[name] ~= nil then
        if over[name] == false then return nil end
        return over[name]
    end
    return PlayerFlags.get(src, name)
end

---@param internal boolean|nil  whip's own names (_...), a Dialog Line's "once ever"
---@return boolean ok
---@return string|nil why
function Director.setFlag(run, src, name, value, internal)
    if run.test then
        if not PlayerFlags.validName(name, internal) then return false, 'that is not a flag name' end
        run.testFlags = run.testFlags or {}
        run.testFlags[src] = run.testFlags[src] or {}
        if value == nil or value == false then run.testFlags[src][name] = false else run.testFlags[src][name] = value end
        return true
    end
    return PlayerFlags.set(src, name, value, internal)
end

--- How many of an item a player carries (pockets, and what their pockets hold).
---@param run table|nil  the run asking
---@param only boolean|nil  only what THIS run placed or gave (Director.onlyOwn): a goal for the scenario's own items
---@return number
function Director.carried(src, item, run, only)
    local p = Players[src]
    if not p or not p.inventory or type(item) ~= 'string' then return 0 end
    local rule = (only and type(run) == 'table') and Director.onlyOwn(run) or nil
    return Inventory.getItemCountAcrossContainers(p.inventory, item, rule) or 0
end

--- The rule for counts and takes of ONLY the run's own stacks (what it placed or gave), never the player's own of
--- the same item: Bring Item To and Collect, which ask for the scenario's items. A test's carry its stamp, a live run's
--- its plain tag (DirectorEffects.ownField).
---@param run table
---@return table
function Director.onlyOwn(run) return Inventory.onlyStamped({ [DirectorEffects.ownField(run)] = run.id }) end

-- ============================================
-- Active scenarios: the standing layer and how runs start
-- ============================================

local coordsOf = DirectorKit.place

--- A placed prop as a prop set piece (server/prop_sets.lua): where it is, how it is turned, and what
--- its game needs to know (an interior to wait for, a lamp, no collision). A Fixed Weapon (def.weapon) is its gun's
--- world model; one attached (def.attach.to) carries what it is on (`attachTo`), resolved as its set is sent
--- (nodes_props.lua). Nil when it is not placed.
---@return table|nil piece
function Director.propPiece(def)
    local c = coordsOf(type(def) == 'table' and def.coords or nil)
    local weapon = type(def) == 'table' and WeaponCatalog.modelOf(def.weapon) and def.weapon:upper() or nil
    local model = weapon and WeaponCatalog.modelOf(weapon) or (type(def) == 'table' and def.model)
    if not c or type(model) ~= 'string' or model == '' then return nil end
    local r = type(def.rot) == 'table' and def.rot or {}
    -- A lamp: the one catalog's Lighting (the Director's props are the furnisher's).
    local row = not weapon and PropCatalog and PropCatalog.get and PropCatalog.get(model) or nil
    local attach = type(def.attach) == 'table' and type(def.attach.to) == 'string' and def.attach.to ~= '' and def.attach.to or nil
    return {
        model = model, coords = { x = c.x, y = c.y, z = c.z },
        rot = { x = tonumber(r.x) or 0.0, y = tonumber(r.y) or 0.0, z = c.heading or 0.0 },
        interior = def.interior == true,
        light = def.light == true or (row ~= nil and row.category == 'lighting'),
        collision = def.collision ~= false,
        weapon = weapon,
        attachTo = attach,
    }
end

--- Make one standing thing. Answers its handle, or nil and why. A test of an isolated builder's
--- (sc.bucket) is made in their world: its NPCs at birth, its props shown to them alone (sc.audience).
local function makeStanding(sc, worldId, w)
    if w.kind == 'prop' then
        local piece = Director.propPiece(w.def)
        if not piece then return nil, 'it has no model or no position' end
        local id = sc.tag .. ':prop:' .. worldId
        -- Physics on (its page): one networked object, as a run's is (nodes_props.lua PHYSICS). One that cannot be made
        -- stands still instead.
        if not DirectorNodes.physicsOff(w, piece) then
            local h, pwhy = DirectorNodes.makePhysical(sc.tag, sc.bucket, id, piece)
            if h then return h end
            say('%s: %s: physics: %s (it stands still)', sc.id, worldId, tostring(pwhy))
        end
        local ok, why = PropSets.show(CORE, id, { props = { piece }, tag = sc.tag, audience = sc.audience })
        if not ok then return nil, why end
        return { propSet = id }
    end
    if w.kind == 'npc' then
        local def = DirectorRoutes.npcDef(w.def)   -- (a copy)
        def.coords = coordsOf(def.coords)
        if not def.coords then return nil, 'it has no position' end
        -- A quest giver does not start a fight it was not written to (fightBack only when it says so).
        local npcId, netId = Npcs.spawn(CORE, def, { tag = sc.tag, fightBack = def.fightBack == true, bucket = sc.bucket })
        if not npcId then return nil, netId end
        local log = function(t) say('%s: %s', sc.id, t) end
        -- Its task list, played by itself whenever nothing else has it (no run starts a standing one's).
        DirectorTasks.playStanding(sc, worldId, w, npcId, log)
        return { npcId = npcId, netId = netId }
    end
    if w.kind == 'groundItem' and type(w.def) == 'table' and type(w.def.keyOf) ~= 'string' then
        -- Its item on the ground while the scenario is on, for anyone to pick up: taken, it is gone until the scenario
        -- comes on again. Stamped with the scenario's tag, so releasing the tag takes it away (below) and a start of
        -- whip clears what one before it left (Director's start). The stamp is the pile's, not the item's: it stays
        -- on the ground (GroundItems.PILE_KEYS), so what the finder takes is theirs to keep and drop.
        local c = coordsOf(w.def.coords)
        if not c then return nil, 'it has no position' end
        if type(w.def.item) ~= 'string' or w.def.item == '' then return nil, 'it has no item' end
        local g, why = GroundItems.createItem({ item = w.def.item, amount = tonumber(w.def.amount) or 1,
            coords = { x = c.x, y = c.y, z = c.z }, heading = c.heading, metadata = { dstanding = sc.tag },
            reason = ('Director: %s (standing)'):format(tostring(sc.id)) })
        if not g then return nil, why end
        return { groundId = g.id }
    end
    return nil, ('a standing %s is not supported yet'):format(tostring(w.kind))
end

-- A scenario's standing item spots go with its tag (switched off, a test over, a build that failed), as its props and
-- NPCs do: found by their stamp. The rows wait on the database, so they are deleted in a thread of their own.
local function standingGround(tag)
    local ids = {}
    for id, row in pairs(GroundItems and GroundItems.cache or {}) do
        local md = type(row) == 'table' and row.metadata or nil
        if type(md) == 'table' and md.dstanding == tag then ids[#ids + 1] = id end
    end
    return ids
end
Registry.onRelease('directorStandingGround', 40, function(owner, tag)
    if owner ~= CORE then return 0 end
    local ids = standingGround(tag)
    if #ids > 0 then
        CreateThread(function()
            for _, id in ipairs(ids) do if GroundItems.getById(id) then GroundItems.deleteItem(id) end end
        end)
    end
    return #ids
end, function(owner, tag)
    if owner ~= CORE then return nil end
    local out = {}
    for _, id in ipairs(standingGround(tag)) do out[#out + 1] = { 'ground', id } end
    return out
end)

--- How many of a scenario's jobs are going (a lead-in, before its Scenario Run Started By Player, is none of them).
local function runsOf(sc)
    local n = 0
    for _, run in ipairs(R.list()) do
        if run.scenarioId == sc.id and not run.test and not run.pre then n = n + 1 end
    end
    return n
end

--- How many runs of a scenario may go at once: its Runs at once; with variants, one per variant at most (empty:
--- one each).
---@return number
function Director.maxRuns(sc)
    local n = tonumber(sc.graph.settings.maxConcurrentRuns)
    local count = sc.variants and #sc.variants or 1
    if count <= 1 then return n or 1 end
    return math.max(1, math.min(count, n or count))
end

--- The variant a new run of a scenario plays: First free (the first not being played), Random (any free one), or
--- In order (the builder's list in turn, a busy one passed over; the next run starts after the one handed out
--- last). nil when every one is busy. `peek`: only asked (CanStartScenarioRun), the order does not move on.
---@return table|nil variant  { id, name, doc, graph }
function Director.pickVariant(sc, peek)
    local list = sc.variants
    if not list or #list <= 1 then return list and list[1] or nil end
    local busy = {}
    for _, r in ipairs(R.list()) do
        -- (A lead-in holds no variant: two may play the same one, and Scenario Run Started By Player lets one of them
        -- start it.)
        if r.scenarioId == sc.id and not r.test and r.variant and not r.pre then busy[r.variant] = true end
    end
    local mode = sc.graph.settings.variantPick
    if mode == 'random' then
        local free = {}
        for _, v in ipairs(list) do if not busy[v.id] then free[#free + 1] = v end end
        return #free > 0 and free[math.random(#free)] or nil
    elseif mode == 'order' then
        for step = 1, #sc.order do
            local i = (sc.orderAt + step - 1) % #sc.order + 1
            local v = sc.variantById[sc.order[i]]
            if v and not busy[v.id] then
                if not peek then sc.orderAt = i end
                return v
            end
        end
        return nil
    end
    for _, v in ipairs(list) do if not busy[v.id] then return v end end
    return nil
end

--- Is the start point free (no run is using up the scenario)? While it is not, everyone else sees
--- it say the NPC is busy (a talk point: server/runtime_points.lua); the players of its runs see
--- nothing on it: they have their own Talk on that NPC when the scenario wants one.
local function refreshStart(sc)
    -- Not one switched off or replaced: its runs ending as it goes would send its point to everyone
    -- again just before its tag takes it away.
    if not sc.pointId or Director.active[sc.id] ~= sc then return end
    local max = Director.maxRuns(sc)
    local people = {}
    for _, run in ipairs(R.list()) do
        if run.scenarioId == sc.id and run.status == 'running' then
            for s in pairs(run.players) do
                if #people < 64 then people[#people + 1] = s end
            end
        end
    end
    RuntimePoints.update(CORE, sc.pointId, { enabled = runsOf(sc) < max, quietFor = #people > 0 and { people = people } or false })
end

--- Is `src` in a run of this scenario (a test of it included)?
local function inRunOf(sc, src)
    for _, run in ipairs(R.list()) do
        if run.scenarioId == sc.id and run.players[src] then return true end
    end
    return false
end
-- The API asks the same questions a start does (CanStartScenarioRun, api.lua).
Director.inRunOf, Director.runsOf = inRunOf, runsOf

--- The players in a run of this scenario now (a test of it included), as a set: for asking it of many
--- players at once (Pick Team's list) without walking the runs for each.
---@return table<number, true>
function Director.inRunSet(sc)
    local set = {}
    for _, run in ipairs(R.list()) do
        if run.scenarioId == sc.id then
            for s in pairs(run.players) do set[s] = true end
        end
    end
    return set
end

--- May this player be in a run of this scenario now? The one answer, for every start and
--- CanStartScenarioRun: on a character, not leaving, not in the character creator, up, not in a world
--- of their own (Isolate world), and not in a run of this scenario already.
---@param sc table|nil  nil: every scenario's question, without the last
---@param opts table|nil  { they = true }: said of someone else ("They are ..."), not of the starter;
---                       { busy = set }: Director.inRunSet(sc), worked out once for many players
---@return boolean ok
---@return string|nil why
function Director.eligible(sc, src, opts)
    local they = type(opts) == 'table' and opts.they == true
    local p = Players[src]
    if not (p and p.charId) or p.closing then return false, they and 'They are not on a character' or 'You are not on a character' end
    if p._inCreator then return false, they and 'They are making their character' or 'You are making your character' end
    if p.isDead then return false, they and 'They are down' or 'You are down' end
    if Director.isolated[src] then
        return false, they and 'They are in their own world (Isolate world)'
            or 'You are in your own world (Isolate world): jobs are played in the shared one'
    end
    if sc then
        local busy = type(opts) == 'table' and opts.busy
        if (busy and busy[src]) or (not busy and inRunOf(sc, src)) then
            return false, they and 'They are already doing this' or 'You are already doing this'
        end
    end
    return true
end

--- Start a run of an active scenario for `source` (who pressed the start point, or an admin).
---
--- A player is never in two runs of the same scenario (they would be paid twice): checked HERE, where
--- every start comes through (each start mode, the editor's Start, /director start, a script). A
--- starter already in one is refused, and a timer's or a script's `with` passes over anyone in one.
---
--- Nobody is put in for standing near the starter: the crew is picked on the team page (Pick Team).
--- (A timer start is the one start made for a group: its `with` is the players near its placed thing,
--- startsTick below.)
---
--- No live run for an isolated builder (Isolate world, hub.lua): a live run's things are made in the
--- shared world, where they are not. Their test is made in their own (sc.bucket, Director.build).
---@param opts table|nil  { test = true }: a test run (Test mode): the tester alone, nothing of value;
---                       { with = { src, ... } }: players in it from the start too (On a timer, a script);
---                       { vars = {...}, places = {...} }: its variables and places, CHECKED already
---                       (StartScenarioRun: Director.checkVars / checkPlaces);
---                       { open = true }: nobody in it (Director.openRun: no `source`)
---@return table|false run
---@return string|nil why
function Director.startRun(sc, source, trigger, opts)
    local test = type(opts) == 'table' and opts.test == true
    local open = not test and type(opts) == 'table' and opts.open == true
    -- (A test is the builder's own, from the editor: only never two of it at once.)
    if test then
        if inRunOf(sc, source) then return false, 'You are already doing this' end
    elseif not open then
        local ok, why = Director.eligible(sc, source)
        if not ok then return false, why end
        -- One that starts When it's switched on has its one run waiting for a player: started by hand or by a script,
        -- they join that one, as if they had come to it.
        if Director.startModeOf(sc) == 'enabled' then
            local waiting = Director.openRunOf(sc) or Director.openRun(sc)
            if not waiting then return false, 'this scenario is already running' end
            local cok, cwhy = Director.claim(waiting, source)
            if not cok then return false, cwhy end
            return waiting
        end
    end
    -- A card of another resource it needs is not here now (its resource stopped), or came back changed
    -- and no longer fits: no new run. Runs going now carry on (cards_api.lua).
    local missing = Director.cardsMissing(sc)
    if missing then return false, missing end
    local players, seen = {}, {}
    if not open then players, seen = { source }, { [source] = true } end
    -- No more than its Team size, however they come in.
    local cap = Director.teamSize(sc)
    if not test and not open and type(opts) == 'table' and type(opts.with) == 'table' then
        for _, s in ipairs(opts.with) do
            -- As AddPlayerToScenarioRun takes them (Director.eligible, and not cooling down); one who may not is passed
            -- over, so one player cooling down never stops a timer's start or a script's `with` for everyone (Josh,
            -- 1 Nov). The starter cooling down is still refused, below.
            if #players < cap and not seen[s] and Director.eligible(sc, s, { they = true })
                and not Director.coolingDown(sc, { players = { [s] = true }, starter = source }) then
                players[#players + 1] = s
                seen[s] = true
            end
        end
    end
    -- Anyone with this scenario open in the editor sees the run's cards light as it goes (hub.lua,
    -- Director.livePulse), from its first card on (so given to the start). A test run's trace is the
    -- tester's strip instead (hub.lua beginTest).
    local live = not test and function(e, r) Director.livePulse(r, e) end or nil
    local o = type(opts) == 'table' and opts or {}
    -- Which variant it plays (a test: the one open in the editor); every one busy: no run, as when Runs at once is full.
    local multi = sc.variants and #sc.variants > 1
    local v = test and (sc.variantById and sc.variantById[o.variant] or sc.variants and sc.variants[1])
        or Director.pickVariant(sc)
    if not v then return false, 'this scenario is already running' end
    -- A scenario whose job starts at its first card (no Scenario Run Started By Player card) asks its cooldown here.
    if not test and not open and not R.hasBegin(v.graph or sc.graph) then
        local set = {}
        for _, s in ipairs(players) do set[s] = true end
        local cooling = Director.coolingDown(sc, { players = set, starter = source })
        if cooling then
            local c = cooling[1]
            return false, c.src == source and ('You can do this job again in %d min'):format(c.mins)
                or ('%s can do this job again in %d min'):format(c.name or 'Someone', c.mins)
        end
    end
    local run, why = R.start(v.graph or sc.graph, { scenarioId = sc.id, rev = sc.rev, players = players, starter = source, trigger = trigger,
                                         test = test, open = open, onTrace = live, vars = not test and o.vars or nil,
                                         places = not test and o.places or nil,
                                         variant = multi and v.id or nil, maxSame = multi and Director.maxRuns(sc) or nil })
    if not run then return false, why end
    SetResourceKvpInt(LAST_RUN_KVP, run.id)   -- (the next start of whip carries on from it: CoreStart below)
    run.variantName = run.variant and v.name or nil
    run.scenario, run.convs, run.payout = sc, {}, 0
    -- Where its cards make things: an isolated tester's world (nil: the shared one), and who sees its props.
    if test then run.bucket, run.propAudience = sc.bucket, sc.audience end
    -- Its props' models loading on the games near them now, not when a card shows them (nodes_props.lua).
    DirectorNodes.readyRunProps(run)
    -- Its cars' takes read now (a thread of their own), so a card or task that plays one never waits for them.
    DirectorTakes.preload(run.graph)
    -- Who each player is, for what is kept by character (map.blip's audiences): their charId can be
    -- gone from Players by the time they leave.
    run.charOf, run.blips = {}, {}
    for s in pairs(run.players) do run.charOf[s] = Players[s] and Players[s].charId or nil end
    -- Its job starts now, or at its Scenario Run Started By Player (Director.beginRun): filed in its history, and its
    -- players told they are in it, from then. A lead-in that never gets there is filed nowhere (nor does a run that
    -- started as its scenario was switched on, until its job starts).
    if not run.pre then
        run.begunAt = run.startedAt
        DirectorStore.runStarted(run)
    end
    Director.event(run, nil, 'started', source)
    refreshStart(sc)
    -- How it started, for scripts: a script's start names the resource (trigger.by).
    local t = type(trigger) == 'table' and trigger or {}
    local start = type(sc.graph.settings.start) == 'table' and sc.graph.settings.start or {}
    local how = open and 'enabled' or t.by and 'script' or ((t.useId or t.item or t.world) and (start.mode or 'admin')) or 'hand'
    Director.announce('run:started', { run = Director.view(run), startedBy = { mode = how, by = t.by } }, run.test)
    if not run.test and not run.pre then
        for s in pairs(run.players) do Director.tellPlayer(run, s, 'joined') end
    end
    return run
end

-- ============================================
-- Scenario Run Started By Player: a run's job starts (after its lead-in)
-- ============================================
--
-- COOLDOWN (settings.cooldownMin): when a run whose job started ends, its characters wait that many minutes before
-- another job of the scenario starts with them in it (Scenario Run Started By Player goes on from Not now, and they
-- are told how long). WHO waits is settings.cooldownWho: 'everyone' in it (the default), or only the 'starter', the
-- player who started it (the crew they bring may come again at once, but not start one). Asked wherever a player
-- comes in: a start, Scenario Run Started By Player, Pick Team and AddPlayerToScenarioRun into a job that has begun
-- (Director.addPlayer), joining a run that started as it was switched on (Director.claim), and CanStartScenarioRun. Kept by character in this resource's KVP, so a restart keeps it. A test, a fault,
-- whip_core stopping and a run cut short from outside (an admin's Abort, the scenario switched off, replaced or
-- deleted, a script switching it: run.cutShort) start none, and a lead-in (no job) never does.

local cooldowns = {}   -- [scenario id] = { [charId as text] = os.time() it ends }

local function cooldownsOf(id)
    local t = cooldowns[id]
    if t then return t end
    local ok, v = pcall(json.decode, GetResourceKvpString('director:cd:' .. id) or '')
    t = ok and type(v) == 'table' and v or {}
    cooldowns[id] = t
    return t
end

local function cooldownSec(sc)
    local m = tonumber(sc and sc.graph.settings.cooldownMin)
    if not m or m ~= m or m <= 0 then return 0 end
    return math.floor(math.min(m, 10080) * 60)
end

--- Who a job's cooldown is for: 'starter' (only the player who started it) or 'everyone' in it.
local function cooldownWho(sc)
    return sc and type(sc.graph.settings) == 'table' and sc.graph.settings.cooldownWho == 'starter' and 'starter' or 'everyone'
end

--- Each character in an ended run starts its scenario's cooldown (or its starter alone: cooldownWho).
local function startCooldowns(run)
    local sc = run.scenario
    local secs = cooldownSec(sc)
    if secs <= 0 then return end
    local t, now = cooldownsOf(sc.id), os.time()
    for k, ends in pairs(t) do
        if not tonumber(ends) or tonumber(ends) <= now then t[k] = nil end
    end
    if cooldownWho(sc) == 'starter' then
        local cid = run.charOf and run.charOf[run.starter]
        if cid then t[tostring(cid)] = now + secs end
    else
        for _, cid in pairs(run.charOf or {}) do t[tostring(cid)] = now + secs end
    end
    SetResourceKvp('director:cd:' .. sc.id, json.encode(t))
end

--- The run's players still cooling down from this scenario: { { src, mins, name } }, or nil for none. `run` is any
--- { players = set, starter? }: with cooldownWho 'starter', only its starter is asked (none named: nobody).
function Director.coolingDown(sc, run)
    if cooldownSec(sc) <= 0 then return nil end
    local t, now, out = cooldownsOf(sc.id), os.time(), nil
    local only = cooldownWho(sc) == 'starter'
    for s in pairs(run.players) do
        local p = (not only or s == run.starter) and Players[s]
        local ends = p and p.charId and tonumber(t[tostring(p.charId)])
        if p and ends and ends > now then
            out = out or {}
            out[#out + 1] = { src = s, mins = math.ceil((ends - now) / 60), name = p.fullName }
        end
    end
    return out
end

--- A run's job starts (its Scenario Run Started By Player card, or the first player joining a run that started as its
--- scenario was switched on, with no such card): no more of the scenario's jobs going at once than its Runs at once (a
--- variant played once at a time), and none of its players cooling down. Answers why not (its players are told), or
--- nil: started, filed in its history from now, its players told they are in it.
function Director.beginRun(run)
    local sc = run.scenario
    if sc and not run.test then
        local going, variantBusy = 0, false
        for _, r in ipairs(R.list()) do
            if r ~= run and r.scenarioId == run.scenarioId and not r.test and not r.pre then
                going = going + 1
                if run.variant and r.variant == run.variant then variantBusy = true end
            end
        end
        if going >= (run.maxSame or Director.maxRuns(sc)) or variantBusy then
            for s in pairs(run.players) do NotifyPlayer(s, 'This job is already going: come back later', 'info') end
            return 'all its runs are going'
        end
        local cooling = Director.coolingDown(sc, run)
        if cooling then
            for s in pairs(run.players) do
                for _, c in ipairs(cooling) do
                    NotifyPlayer(s, c.src == s and ('You can do this job again in %d min'):format(c.mins)
                        or ('%s can do this job again in %d min'):format(c.name or 'Someone', c.mins), 'info')
                end
            end
            return 'a player is cooling down'
        end
    end
    run.pre = nil
    run.begunAt = GetGameTimer()
    R.begun(run)   -- (one that opened with nobody in it: its time limit from now)
    DirectorStore.runStarted(run)
    if sc then refreshStart(sc) end
    if not run.test then
        for s in pairs(run.players) do Director.tellPlayer(run, s, 'joined') end
    end
    return nil
end

-- ============================================
-- When it's switched on: a run with nobody in it yet (an open run)
-- ============================================
--
-- A scenario whose runs start When it's switched on (settings.start.mode 'enabled') has ONE run at a time, started as
-- it is switched on (and as whip_core comes up with it on): its Scenario Enabled cards play at once, with nobody in it,
-- and what they make is out for everyone. A card that acts for a player (a Dialog Line, Wait for Press, Player Arrives,
-- an Interaction Menu) waits for ANYONE meanwhile: the first player to talk, press or come near joins the run
-- (Director.claim) and the card plays for them. Its job starts at Scenario Run Started By Player, or, with no such card,
-- as they join. When the run is over (whatever the outcome) a new one starts, so the next player finds it as new; one
-- that ended before anyone joined (a Succeed with nobody there) does not, until it is switched off and on.

local REOPEN_MS = 2000   -- after a run ends: what it made gone first

local function startModeOf(sc)
    local st = sc and sc.graph and sc.graph.settings and sc.graph.settings.start
    return type(st) == 'table' and st.mode or 'admin'
end
Director.startModeOf = startModeOf

--- The run of a scenario that starts When it's switched on, going now (with a player in it or not), or nil.
function Director.openRunOf(sc)
    for _, run in ipairs(R.list()) do
        if run.scenarioId == sc.id and run.opened and not run.test and run.status == 'running' then return run end
    end
    return nil
end

--- Start the run of a scenario that starts When it's switched on, unless one is going. nil and why when it cannot.
---@return table|nil run
---@return string|nil why
function Director.openRun(sc)
    if not sc or Director.active[sc.id] ~= sc then return nil, 'it is not switched on' end
    if startModeOf(sc) ~= 'enabled' then return nil, 'it does not start when switched on' end
    if Director.openRunOf(sc) then return nil, 'its run is going' end
    local run, why = Director.startRun(sc, nil, nil, { open = true })
    if not run then say('^3scenario %s: its run could not start: %s^0', sc.id, tostring(why)) return nil, why end
    return run
end

--- A player joins an open run: its first player (its starter from now). The one way in for the cards that wait for
--- anyone (Director.waitForAnyone, Wait for Press, Player Arrives, Interaction Menu) and for a start by hand or by a
--- script. Answers true, or false and why (said to them by the card's prompt).
---@return boolean ok
---@return string|nil why
function Director.claim(run, src)
    if not run or run.status ~= 'running' then return false, 'It is over' end
    -- (One of its players already, in a run still open, is not a short cut: the claim is finished for them.)
    if run.players[src] and not run.open then return true end
    if not run.open then return false, 'Someone is doing this already' end
    local sc = run.scenario
    local ok, why = Director.eligible(sc, src)
    if not ok then return false, why end
    -- With no Scenario Run Started By Player card its job starts as they join: its Runs at once and their cooldown now,
    -- filed with them as its starter.
    run.starter = src
    if run.pre and not R.hasBegin(run.graph) then
        local cooling = Director.coolingDown(sc, { players = { [src] = true }, starter = src })
        if cooling then
            run.starter = nil
            return false, ('You can do this job again in %d min'):format(cooling[1].mins)
        end
        if Director.beginRun(run) then
            run.starter = nil
            return false, 'This job is already going: come back later'
        end
    end
    if not run.players[src] then
        local added, awhy = Director.addPlayer(run, src)
        if not added then
            run.starter = nil
            return false, awhy
        end
    end
    run.claimedAt = GetGameTimer()
    R.claimed(run)
    return true
end

--- A card that acts for a player, reached in an open run with nobody in it yet (Director.playerOf answers nil): a Talk
--- point on its NPC for anyone instead. The first to press it joins the run (Director.claim), and the card plays again
--- from that press, as if they had set it off (R.pulse); a player who joins some other way meanwhile has it played for
--- them too. Answers nil (the card waits), or `fallback` when the run is not open (nobody to wait for).
---@param h table   the NPC's handle (netId)
function Director.waitForAnyone(ctx, npcW, h, label, fallback)
    local run, node = ctx.run, ctx.node
    if not run.open then return fallback end
    local pin = ctx.pin
    -- (A press on this point that claimed the run pulses the card itself: the poll below must not pulse it again.)
    local pressed = false
    local pointId, why = RuntimePoints.add(CORE, {
        at = { netId = h.netId, offset = vector3(0.0, 0.0, 0.3) }, label = label or 'Talk', reach = 2.5, tag = ctx:tag(),
        talk = true,
        onUse = function(source, use)
            local ok, cwhy = Director.claim(run, source)
            if not ok then return false, cwhy end
            pressed = true
            R.pulse(run, node.id, pin, { source = source, useId = use.useId, world = npcW })
        end,
    })
    if not pointId then
        ctx:log('could not offer a Talk point to anyone: %s', tostring(why))
        return fallback
    end
    -- (Waits until then; joined another way, played for that player.)
    ctx:poll(500, function()
        if pressed then return nil end
        local s = run.starter
        if s and run.players[s] and not run.open then R.pulse(run, node.id, pin, { source = s }) end
        return nil
    end)
    ctx:onEnd(function() RuntimePoints.remove(CORE, pointId) end)
    return nil
end

-- ============================================
-- How a switched-on scenario's runs begin (settings.start.mode)
-- ============================================
--
--   interaction  Talk on a standing NPC
--   press        a prompt (E) at a placed thing: a laptop, a keypad, a job board
--   area         a player comes within a distance of a placed thing. Once a visit: someone still
--                standing there when their run ends must leave and come back
--   item         a player uses an item (whip_core holds its use while the scenario is on)
--   timer        every N minutes, for the players near a placed thing; nobody near: the next time
--   script       another resource asks: exports.whip_core:StartScenarioRun(key, source)
--   admin        by hand only: Start a run in the editor, or /director start <key>
-- Every one of them can also be started by hand. However it starts, a player is never in two runs of
-- the same scenario at once (Director.startRun).

local itemStarts = {}   -- [itemKey] = the scenario it starts, while that scenario is on

--- A run for a player by a start mode. Who may start one is Director.eligible's to say, which
--- Director.startRun asks for every start.
---@return table|false run
---@return string|nil why  said to them (an item use, a press)
local function startFor(sc, src, trigger, opts)
    return Director.startRun(sc, src, trigger, opts)
end

--- A timer's minutes, as Check allows them.
local function everyMinutes(start)
    return math.max(1, math.min(1440, tonumber(start.every) or 30))
end

local function startRadius(start)
    return math.max(1, math.min(500, tonumber(start.radius) or 10))
end

--- Where every player who could be in a run is (Director.eligible, any scenario), read once a tick and
--- shared by every scenario that asks.
local function eligiblePositions()
    local out = {}
    for src in pairs(Players) do
        if Director.eligible(nil, src) then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                out[#out + 1] = { src = src, x = c.x, y = c.y, z = c.z }
            end
        end
    end
    return out
end

--- Of those (eligiblePositions), the ones within `radius` of a spot; nearest first.
local function playersNear(at, radius, everyone)
    local out = {}
    local r2 = radius * radius
    for _, e in ipairs(everyone) do
        local dx, dy, dz = e.x - at.x, e.y - at.y, e.z - at.z
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 <= r2 then out[#out + 1] = { src = e.src, d2 = d2 } end
    end
    table.sort(out, function(a, b) return a.d2 < b.d2 or (a.d2 == b.d2 and a.src < b.src) end)
    return out
end
-- (Player Arrives asks the same of a run nobody has joined yet: the first to come near joins it.)
Director.eligibleNow, Director.playersNear = eligiblePositions, playersNear

--- One look, a second apart, at every scenario that starts by a player coming near or by a timer.
local function startsTick()
    local any = false
    local now = GetGameTimer()
    local everyone   -- (eligiblePositions, read the first time a scenario asks this tick)
    local function all()
        everyone = everyone or eligiblePositions()
        return everyone
    end
    local ids = {}
    for id in pairs(Director.active) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local sc = Director.active[id]
        local start = sc and sc.graph.settings.start
        local mode = type(start) == 'table' and start.mode or nil
        if mode == 'area' and sc.startAt then
            any = true
            -- Once a visit: in when a run starts for them (or they are in one), out when they leave.
            -- One who could not have a run (all its runs are going) is asked again each second, and told why once a
            -- visit (sc.toldWhy).
            local near, busy = {}, nil
            local here = sc.startSpot and DirectorSpots.startersIn(sc.startSpot, all())
                or playersNear(sc.startAt, startRadius(start), all())
            for _, e in ipairs(here) do
                near[e.src] = true
                if not sc.inside[e.src] then
                    busy = busy or Director.inRunSet(sc)
                    if busy[e.src] then
                        sc.inside[e.src] = true
                    else
                        local run, why = startFor(sc, e.src, { source = e.src, world = start.world })
                        if run then
                            sc.inside[e.src] = true
                            for s in pairs(run.players) do sc.inside[s] = true end
                        elseif not sc.toldWhy[e.src] then
                            sc.toldWhy[e.src] = true
                            NotifyPlayer(e.src, tostring(why or 'This job cannot start now'), 'info')
                        end
                    end
                end
            end
            for s in pairs(sc.inside) do
                if not near[s] then sc.inside[s] = nil end
            end
            for s in pairs(sc.toldWhy) do
                if not near[s] then sc.toldWhy[s] = nil end
            end
        elseif mode == 'timer' and sc.nextAt then
            any = true
            if now >= sc.nextAt then
                sc.nextAt = now + math.floor(everyMinutes(start) * 60000)
                local list = {}
                local busy = Director.inRunSet(sc)
                for _, e in ipairs(playersNear(sc.startAt, startRadius(start), all())) do
                    if not busy[e.src] then list[#list + 1] = e.src end
                end
                -- The one who starts it: the nearest who is not cooling down (one who is cannot hold everyone up)
                for i, s in ipairs(list) do
                    if not Director.coolingDown(sc, { players = { [s] = true }, starter = s }) then
                        if i > 1 then table.remove(list, i) table.insert(list, 1, s) end
                        break
                    end
                end
                if #list == 0 then
                    say('scenario %s: its timer came round, and nobody was near', id)
                else
                    local with = {}
                    for i = 2, #list do with[#with + 1] = list[i] end
                    local run, why = startFor(sc, list[1], { source = list[1], world = start.world }, { with = with })
                    if not run then say('scenario %s: its timer came round, but no run started: %s', id, tostring(why)) end
                end
            end
        end
    end
    return any and 1000 or 2000
end

Every('director-starts', 2000, startsTick)

--- Of a "Use an item" start (Check): who already does something when the item is used (a resource, or whip_core), or
--- nil when nothing does or a scenario does (activation sorts those out).
function Director.itemUseOwner(key)
    local owner = Inventory.handlerOwner('use', key)
    if owner == CORE and itemStarts[key] ~= nil then return nil end
    return owner
end

--- What a player did in a run, on the record (the scenario's Interactions tab).
function Director.event(run, nodeId, kind, src, detail)
    DirectorStore.event(run, nodeId, kind, src, detail)
end

--- What a failed build says, as Check would: the placed thing it is about and the cards that name it,
--- so the editor lights them up (a ped model the game does not have, say).
---@return table problems
function Director.buildProblem(doc, why, worldId)
    return { { severity = 'error', message = tostring(why), world = worldId,
               nodes = worldId and DirectorGraph.usesOfWorld(doc, worldId) or {}, tab = worldId and 'world' or nil } }
end

--- Why a scenario would not switch on, in words for the console: Check's errors (each with its card and
--- variant), or the reason it gave. A switch-on refused by the server itself says it here, never only "its
--- check failed".
---@param res any  Director.activate's second answer, or any other reason (said as text)
---@return string
function Director.whyNotOn(res)
    if type(res) ~= 'table' then return tostring(res) end
    local errs = {}
    for _, p in ipairs(res) do
        if type(p) == 'table' and p.severity == 'error' then
            local where = p.node and (' (card ' .. tostring(p.node) .. ')') or (p.world and (' (' .. tostring(p.world) .. ')') or '')
            local variant = p.variantName and (tostring(p.variantName) .. ': ') or ''
            errs[#errs + 1] = variant .. tostring(p.message) .. where
        end
    end
    if #errs == 0 then return 'its check failed' end
    local shown = {}
    for i = 1, math.min(5, #errs) do shown[i] = errs[i] end
    return ('its check failed: %s%s'):format(table.concat(shown, '; '), #errs > 5 and (' (and %d more)'):format(#errs - 5) or '')
end

--- A CHECKED document compiled, with its standing layer made under a fresh tag. Answers the
--- scenario record, or false, why and the placed thing it failed on. Activation and Test mode both
--- build one; a test's lives under `test:<id>:<serial>`, so it is never confused with the live one.
---@param opts table  { dbId, rev, prefix = 'standing' | 'test',
---                     bucket?, audience? (an isolated builder's test: made in their world, props for them) }
---@return table|false sc
---@return string|nil why
---@return string|nil worldId
function Director.build(id, raw, opts)
    -- Read the one way (doc.lua): Test mode builds what the editor sent, activation what it checked.
    local doc, lwhy = DirectorDoc.load(raw)
    if not doc then return false, lwhy end
    -- Each variant compiled (one, with none); Variant 1's graph is the scenario's (its standing layer, start and
    -- settings are every variant's: graph.lua).
    local variants, byId = {}, {}
    for i, v in ipairs(DirectorGraph.variantsOf(doc)) do
        -- (Its name, or "Variant 2" by where it is in the list: what the editor's buttons say.)
        local name = (type(v.name) == 'string' and v.name ~= '') and v.name or ('Variant ' .. i)
        local e = { id = v.id, n = i, name = name, doc = v.doc, graph = DirectorGraph.compile(v.doc) }
        variants[#variants + 1] = e
        byId[v.id] = e
    end
    local graph = variants[1].graph
    serial = serial + 1
    local sc = { id = id, name = doc.name or id, rev = opts.rev or doc.rev or 1, doc = doc, graph = graph,
                 dbId = opts.dbId, tag = ('%s:%s:%d'):format(opts.prefix or 'standing', id, serial), standing = {},
                 bucket = opts.bucket, audience = opts.audience, variants = variants, variantById = byId, orderAt = 0 }
    -- In order: the builder's list of the ones there are (none: the variants' own order).
    sc.order = {}
    local settings = type(doc.settings) == 'table' and doc.settings or {}
    for _, vid in ipairs(type(settings.variantOrder) == 'table' and settings.variantOrder or {}) do
        if byId[vid] then sc.order[#sc.order + 1] = vid end
    end
    if #sc.order == 0 then
        for _, v in ipairs(variants) do sc.order[#sc.order + 1] = v.id end
    end
    -- Every variant's things, for what names one of any variant (StartScenarioRun's places).
    if #variants > 1 then
        sc.allWorld = {}
        for _, v in ipairs(variants) do
            for wid, w in pairs(v.graph.world) do sc.allWorld[wid] = sc.allWorld[wid] or w end
        end
    end
    local ids = {}
    for wid, w in pairs(graph.world) do if w.layer == 'standing' then ids[#ids + 1] = wid end end
    table.sort(ids)
    for _, wid in ipairs(ids) do
        local w = graph.world[wid]
        local h, why = makeStanding(sc, wid, w)
        if not h then
            Registry.releaseTag(CORE, sc.tag)
            local name = type(w.label) == 'string' and w.label ~= '' and w.label or wid
            return false, ('"%s" could not be made: %s'):format(name, tostring(why)), wid
        end
        sc.standing[wid] = h
    end
    -- All made: other resources hear of each (whip_core:run:thingMade, standing = true), as a run's are told: what a
    -- resource keeps on a thing is how it comes out (a car's Whiplash look), here too.
    for _, wid in ipairs(ids) do
        if type(sc.standing[wid]) == 'table' then Director.standingMade(sc, wid, sc.standing[wid], opts.prefix == 'test') end
    end
    return sc
end

--- Activate a scenario document: checked, compiled, its standing layer made, its start point up.
---@param id string
---@param raw table
---@param opts table|nil  { dbId, rev }: a scenario from the store (its runs go in its history);
---                       { by = source }: who switched it on (for scripts: scenario:switchedOn)
---@return boolean ok
---@return table|string problemsOrWhy
function Director.activate(id, raw, opts)
    opts = opts or {}
    -- Read the one way (doc.lua), then checked. (A document Check cannot read is refused as one with an error: it
    -- never stops what switches others on. Only read here: the build below loads its own copy.)
    local doc, lwhy = DirectorDoc.read(raw)
    if not doc then return false, { { severity = 'error', message = lwhy } } end
    local readable, ok, problems = pcall(DirectorGraph.check, doc)
    if not readable then
        say('^1scenario %s: Check could not read it: %s^0', tostring(id), tostring(ok))
        return false, { { severity = 'error', message = 'Check could not read this scenario: ' .. tostring(ok) } }
    end
    if not ok then return false, problems end
    -- Never while a builder tests it: its live things would stand where the test's do (hub.lua refuses the other way).
    if Director.isTesting(id) then return false, TESTING end
    local old = Director.active[id]
    local replacing = old ~= nil
    if replacing then Director.deactivate(id, 'replaced') end
    -- The one that was on is down ('replaced' says nothing outside): if this one does not come up,
    -- the scenario is OFF, and scripts are told so.
    local function lost(why)
        if not replacing then return end
        Director.announce('scenario:switchedOff', { scenario = id, name = old.name, rev = old.rev,
                                                    why = 'its new revision could not be switched on: ' .. tostring(why),
                                                    by = Director.byOf(opts.by) })
    end

    local built, sc, bwhy, bworld = pcall(Director.build, id, doc, { dbId = opts.dbId, rev = opts.rev, prefix = 'standing' })
    if not built then sc, bwhy = false, 'it could not be built: ' .. tostring(sc) end
    if not sc then
        lost(bwhy)
        return false, Director.buildProblem(doc, bwhy, bworld)
    end
    -- (Asked again: making the standing layer waits, and a Test may have begun meanwhile.)
    if Director.isTesting(id) then
        Registry.releaseTag(CORE, sc.tag)
        lost(TESTING)
        return false, TESTING
    end
    local graph = sc.graph
    local ids = {}
    for wid in pairs(sc.standing) do ids[#ids + 1] = wid end

    local start = type(graph.settings.start) == 'table' and graph.settings.start or { mode = 'admin' }
    local mode = start.mode or 'admin'
    local function fail(why)
        Registry.releaseTag(CORE, sc.tag)
        lost('start: ' .. tostring(why))
        return false, 'start: ' .. tostring(why)
    end
    if mode == 'interaction' or mode == 'press' then
        local talk = mode == 'interaction'
        local h = sc.standing[start.world]
        local at
        if type(h) == 'table' and h.netId then
            at = { netId = h.netId, offset = vector3(0.0, 0.0, 0.3) }
        elseif talk then
            return fail(('"%s" is not a standing NPC'):format(tostring(start.world)))
        else
            -- Press something: a prompt where the thing was placed (a standing prop, a spot).
            local w = graph.world[start.world]
            local c = coordsOf(type(w) == 'table' and type(w.def) == 'table' and w.def.coords or nil)
            if not c then return fail(('"%s" has no spot'):format(tostring(start.world))) end
            at = { coords = vector3(c.x, c.y, c.z) }
        end
        local pointId, why = RuntimePoints.add(CORE, {
            at = at, label = start.label or (talk and 'Talk' or 'Use'),
            icon = start.icon, reach = talk and 2.5 or 2.0, tag = sc.tag,
            talk = talk,   -- an NPC says it is busy rather than vanishing (refreshStart, above)
            onUse = function(source, use)
                local trigger = { source = source, useId = use.useId, pointId = use.pointId, world = start.world }
                local run, rwhy
                if talk then run, rwhy = Director.startRun(sc, source, trigger) else run, rwhy = startFor(sc, source, trigger) end
                if not run then return false, rwhy end
            end,
        })
        if not pointId then return fail('the start point: ' .. tostring(why)) end
        sc.pointId = pointId
    elseif mode == 'item' then
        -- Use an item: whip_core holds the item's use while the scenario is on (under its tag, so
        -- switching it off gives it back). Never an item that already does something when used, and
        -- never one another scenario starts with: the registry would let whip_core's own replace it.
        local key = start.item
        if itemStarts[key] ~= nil and itemStarts[key] ~= id then
            return fail(('"%s" already starts the scenario %s'):format(tostring(key), tostring(itemStarts[key])))
        end
        if itemStarts[key] == nil and Inventory.handlerOwner('use', key) ~= nil then
            return fail(('"%s" already does something when used (%s)'):format(tostring(key), tostring(Inventory.handlerOwner('use', key))))
        end
        local registered, why = Inventory.registerTaggedUseHandler(key, function(source)
            local run, rwhy = startFor(sc, source, { source = source, item = key })
            if not run then return false, rwhy end
            if start.consume == true then return nil end   -- used up
            return false                                    -- kept
        end, sc.tag)
        if not registered then return fail(why) end
        itemStarts[key] = id
        sc.item = key
    elseif mode == 'area' or mode == 'timer' then
        local w = graph.world[start.world]
        local c = coordsOf(type(w) == 'table' and type(w.def) == 'table' and w.def.coords or nil)
        if not c then return fail(('"%s" has no spot'):format(tostring(start.world))) end
        sc.startAt, sc.inside, sc.toldWhy = c, {}, {}
        -- A spot with a marker: its shape, and a car driven into it when it activates by a vehicle (spots.lua).
        sc.startSpot = mode == 'area' and DirectorSpots.rules(w) or nil
        if mode == 'timer' then sc.nextAt = GetGameTimer() + math.floor(everyMinutes(start) * 60000) end
    end
    Director.active[id] = sc
    -- Switched on by a script (SwitchScenario) is said in the hub; by anyone else, that is forgotten.
    Director.scriptSwitched[id] = opts.byResource and { on = true, by = opts.byResource, at = os.time() } or nil
    say('scenario %s (rev %s) is active: %d standing thing(s), runs start %s%s', id, tostring(sc.rev), #ids,
        mode == 'enabled' and 'as it is switched on' or ('by ' .. mode), opts.byResource and (', switched on by ' .. opts.byResource) or '')
    Director.announce('scenario:switchedOn', { scenario = id, name = sc.name, rev = sc.rev, replaced = replacing,
                                               by = opts.byResource and { resource = opts.byResource } or Director.byOf(opts.by) })
    -- When it's switched on: its run, with nobody in it yet (its Scenario Enabled cards play now).
    if mode == 'enabled' then Director.openRun(sc) end
    return true, problems
end

--- Who did something, for scripts: { source, name } for a player, nil for the server itself.
---@return table|nil
function Director.byOf(src)
    local p = type(src) == 'number' and Players[src] or nil
    if not p then return nil end
    return { source = src, name = p.fullName }
end

--- What scripts switched (SwitchScenario): [key] = { on, by = resource, at }. In memory only: the
--- store keeps what a person chose, so a reboot puts that back. A person (or the server) switching it
--- again forgets it.
Director.scriptSwitched = {}

--- End a run from outside it (an admin's Abort, its scenario switched off, replaced or deleted): aborted, and nobody
--- in it starts a cooldown (they did not choose to end it: Director.runEnded).
---@return boolean ok  false: no such run
function Director.cutShort(runId, why)
    local run = R.get(runId)
    if not run then return false end
    run.cutShort = true
    return R.abort(runId, why)
end

--- Take a scenario down: its runs end, its standing layer goes.
---@param by number|nil  who switched it off (for scripts: scenario:switchedOff)
---@param byResource string|nil  a script did (SwitchScenario): kept in Director.scriptSwitched
function Director.deactivate(id, why, by, byResource)
    local sc = Director.active[id]
    if not sc then return false, 'that scenario is not active' end
    Director.active[id] = nil
    -- (Its live runs: a builder's Test is theirs, ended by its own Stop.)
    for _, run in ipairs(R.list()) do
        if run.scenarioId == id and not run.test then Director.cutShort(run.id, why or 'the scenario was switched off') end
    end
    Registry.releaseTag(CORE, sc.tag)   -- its start point, its item's use, its standing layer
    if sc.item and itemStarts[sc.item] == id then itemStarts[sc.item] = nil end
    say('scenario %s is off (%s)', id, tostring(why or 'switched off'))
    -- Switching on another revision is not "off" to anyone outside: switchedOn says replaced.
    if why ~= 'replaced' then
        Director.scriptSwitched[id] = byResource and { on = false, by = byResource, at = os.time() } or nil
        Director.announce('scenario:switchedOff', { scenario = id, name = sc.name, rev = sc.rev, why = why or 'switched off',
                                                    by = byResource and { resource = byResource } or Director.byOf(by) })
    end
    return true
end

--- A script switching a scenario on or off (SwitchScenario): only one whose Settings say "Scripts may
--- switch it on and off", only back on at the revision a PERSON last switched on (never a draft no one
--- did), never while a builder tests it, and in memory only (the store keeps the person's choice: a
--- reboot puts it back). WAITS (switching on reads the revision).
---@return boolean ok
---@return string|nil why
function Director.switchByScript(key, on, why, by)
    local row = DirectorStore.get(key)
    if not row then return false, 'No stored scenario called ' .. tostring(key) end
    local function testing() return Director.isTesting(key) end
    if testing() then return false, 'a builder is testing it' end
    local NOT_SCRIPTS = 'its Settings do not let scripts switch it on and off'
    --- The revision a person switched on allows scripts (read: WAITS).
    local function revisionAllows()
        local doc, dwhy = DirectorStore.revision(key, row.activeRev)
        if not doc then return nil, dwhy --[[@as string]] end
        if not (type(doc.settings) == 'table' and doc.settings.scriptSwitch == true) then return nil, NOT_SCRIPTS end
        return doc
    end
    local sc = Director.active[key]
    -- Its runs are called off with the script's reason, and the script's name said with it.
    local said = ('%s (switched off by %s)'):format(why or 'switched off', by)
    if not on then
        if not sc then
            -- Off by a person already (or never on): nothing to remember.
            if row.status ~= 'active' or not row.activeRev then return true end
            -- Off in the world, but meant to be on (its pack restarting, the server starting): remembered,
            -- so that coming back does not switch it on behind the script (the pack's bringBack and the
            -- boot ask Director.scriptSwitched first). Only if its revision lets scripts.
            local doc, dwhy = revisionAllows()
            if not doc then return false, dwhy end
            sc = Director.active[key]   -- after the wait: switched on meanwhile is switched off below
            if not sc then
                local now = DirectorStore.get(key)
                if now and now.status == 'active' then Director.scriptSwitched[key] = { on = false, by = by, at = os.time() } end
                return true
            end
            if testing() then return false, 'a builder is testing it' end
        end
        if sc.graph.settings.scriptSwitch ~= true then return false, NOT_SCRIPTS end
        Director.deactivate(key, said, nil, by)
        return true
    end
    if sc then return true end
    if row.status ~= 'active' or not row.activeRev then
        return false, 'a builder must switch it on first (it is off, by a person, or has never been on)'
    end
    local mayOn, packWhy = DirectorPacks.mayActivate(key)
    if not mayOn then return false, packWhy end
    local doc, dwhy = revisionAllows()
    if not doc then return false, dwhy end
    -- After the wait, asked again (house rule: what you hold may have changed while the database answered):
    -- a person switching it off, a builder starting a Test, its pack stopping.
    if Director.active[key] then return true end
    local now = DirectorStore.get(key)
    if not now or now.status ~= 'active' or now.activeRev ~= row.activeRev then
        return false, 'a person switched it while it was being switched on'
    end
    if testing() then return false, 'a builder is testing it' end
    mayOn, packWhy = DirectorPacks.mayActivate(key)
    if not mayOn then return false, packWhy end
    -- A script is not a person: never with another resource's card than the one a person accepted.
    local moved = Director.cardsChangedHands(key, doc)
    if moved then return false, moved end
    local ok, res = Director.activate(key, doc, { dbId = row.id, rev = row.activeRev, byResource = by })
    if not ok then return false, Director.whyNotOn(res) end
    return true
end

--- A run of a switched-on scenario whose runs start "From a script", for a player: a phone app, a job
--- menu. StartScenarioRun(key, who, opts?) -> runId | false, why. Only scenarios set to start that way
--- (Settings), so a builder decides which ones a script may start; and one that starts "When it's switched on",
--- whose one run waits for a player: they join that run (its id), as if they had come to it (opts.with join too;
--- its variables and places are its own already, so opts.vars and opts.places are refused).
---   opts.with   = { who, ... }   more players in it from the start (crew)
---   opts.vars   = { name = v }   its variables, of the types the scenario declares them
---   opts.places = { [placedThingId] = { x, y, z, heading } }   where this run's NPCs, car, items,
---                 containers and spots are (today's territory): the one accepted scenario, anywhere
exports('StartScenarioRun', function(key, who, opts)
    local by = Registry.caller()   -- first, before anything can wait
    local sc = type(key) == 'string' and Director.active[key] or nil
    if not sc then return false, 'that scenario is not switched on' end
    local start = sc.graph.settings.start
    local mode = type(start) == 'table' and start.mode or nil
    if mode ~= 'script' and mode ~= 'enabled' then
        return false, 'that scenario does not start from a script (its Settings: A run starts)'
    end
    if mode == 'enabled' and type(opts) == 'table' and (opts.vars ~= nil or opts.places ~= nil) then
        return false, 'that scenario\'s run is waiting already, with its own variables and places: only opts.with may be given'
    end
    -- A person is a server id or { charId = n } (house rule; CanStartScenarioRun asks the same way).
    local _, src = WhoIs(who)
    if type(src) ~= 'number' then return false, 'that player is not online (a server id, or { charId = n })' end
    if opts ~= nil and type(opts) ~= 'table' then return false, 'opts is a table: { with, vars, places }' end
    opts = opts or {}
    local o = {}
    if opts.vars ~= nil then
        local vars, vwhy = Director.checkVars(sc.graph, opts.vars)
        if not vars then return false, vwhy end
        o.vars = vars
    end
    if opts.places ~= nil then
        -- (Any variant's things: the run takes the ones of the variant it plays.)
        local places, pwhy = Director.checkPlaces(sc.allWorld and { world = sc.allWorld } or sc.graph, opts.places)
        if not places then return false, pwhy end
        o.places = places
    end
    if opts.with ~= nil then
        if type(opts.with) ~= 'table' then return false, 'opts.with is a list of players' end
        o.with = {}
        for _, w in ipairs(opts.with) do
            local _, s = WhoIs(w)
            if type(s) == 'number' and s ~= src then o.with[#o.with + 1] = s end
        end
    end
    local run, why = startFor(sc, src, { source = src, by = by }, o)
    if not run then return false, why end
    -- (The waiting run of one that starts When it's switched on took only them: their crew joins it, as
    -- AddPlayerToScenarioRun adds one.)
    if mode == 'enabled' then
        for _, s in ipairs(o.with or {}) do
            local ok, awhy = Director.addPlayer(run, s, by)
            if not ok then say('^3StartScenarioRun %s: %s did not join: %s^0', tostring(key), tostring(s), tostring(awhy)) end
        end
    end
    return run.id
end)

-- ============================================
-- A run ends
-- ============================================

local OUTCOME_TEXT = { succeeded = 'Done.', failed = 'Failed.', aborted = 'Called off.', faulted = 'Something went wrong with this job.' }

-- (What a run handed out, taken back as it ends, and where its items may go: DirectorEffects.takeBack and
-- Stores.placementVeto, effects.lua.)

--- THE ONE END RECORD: how a run ended, decided once, and read by everything its end does (the cooldown, what its
--- players are told, what is given back, the API, a reopen). Never from the reason's words: those are for people.
---   outcome   the runtime's ('succeeded' | 'failed' | 'aborted' | 'faulted'); public: the API's (publicOutcome)
---   stopping  whip_core is stopping (CoreStop): nothing is given back or reopened, nobody is cooled down or told
---   cooldown  its players wait (settings.cooldownMin): once its job started (run.begunAt), never a test's, a fault's,
---             one cut short from outside (an admin, the scenario switched off: run.cutShort) or a Call Off ("no
---             thanks" is a job never really taken: run.calledOff, runtime.lua)
---   told      its players hear it was stopped: an abort they did not see coming (not a quiet one, nor a test's)
---   reopens   When it's switched on: a new run for the next player, once one had joined this one (or it was cut
---             short, to put its NPC back say); one that ended before anyone joined waits for a switch off and on
local function endOf(run, outcome, reason)
    local stopping = (CoreStop and CoreStop.running) == true
    local live = not run.test and not stopping
    return {
        outcome = outcome, reason = reason, public = Director.publicOutcome(run, outcome), stopping = stopping,
        cooldown = live and run.begunAt ~= nil and outcome ~= 'faulted' and not run.calledOff and not run.cutShort,
        told = live and outcome == 'aborted' and not run.quiet,
        opened = live and run.opened == true and run.scenario ~= nil,
        reopens = live and run.opened == true and run.scenario ~= nil and (run.claimedAt ~= nil or run.cutShort == true),
    }
end

--- Ports.onEnd: runs in a thread of its own, at once (also inside whip_core's stop).
function Director.runEnded(run, outcome, reason)
    local e = endOf(run, outcome, reason)
    if run.test then Director.cardTestEnded(run) end
    -- What scripts are told it was, read before anything it made goes (the Director API).
    local view = Director.view(run)
    -- Everything made under its tag, whoever made it: whip_core's cards, and a script's blip or point
    -- put up with the run's tag. Closed for everyone: a late create under it is refused.
    Registry.releaseTagEverywhere(run.tag)
    DirectorStore.runEnded(run, outcome, reason)
    if e.cooldown then
        local ok, err = pcall(startCooldowns, run)
        if not ok then say('^1run %d: its cooldown could not be kept: %s^0', run.id, tostring(err)) end
    end
    DirectorTalk.runEnded(run)
    DirectorSpeakers.runEnded(run)   -- the songs it plays on speakers stop with it
    if run.scenario then refreshStart(run.scenario) end
    -- A test's own end goes to its strip (server/director/hub.lua), not to a notification.
    if run.test then
        local ok, err = pcall(Director.testEnded, run, outcome, reason)
        if not ok then say('^1a test\'s end failed: %s^0', tostring(err)) end
    end
    if outcome == 'faulted' then
        for s in pairs(run.players) do NotifyPlayer(s, OUTCOME_TEXT.faulted, 'error') end
    elseif e.told then
        for s in pairs(run.players) do NotifyPlayer(s, OUTCOME_TEXT.aborted .. (reason and (' ' .. reason) or ''), 'warning') end
    end
    -- What it handed out, back (not while whip_core stops: the pockets are being saved as they are).
    if not e.stopping then
        for s in pairs(run.players) do
            local ok, n, what = pcall(DirectorEffects.takeBack, run, s)
            if not ok then
                say('^1run %d: taking its items back from %s failed: %s^0', run.id, tostring(s), tostring(n))
            elseif n > 0 and not run.test then
                NotifyPlayer(s, ('%s taken back: the job is over'):format(what or 'Its items'), 'info')
            end
        end
    end
    -- What its ledger holds (CTX:own: the piles it put down, ground items being rows the tag does not reach), given
    -- back; whip_core stopping, what is saved as it lies stays for the boot's sweep.
    R.release(run, e.stopping and 'stopping' or 'ended')
    -- And any stack of its items dropped since (a new row that kept the stamp).
    if not e.stopping then
        local gone = {}
        for gid, row in pairs(GroundItems and GroundItems.cache or {}) do
            local md = type(row) == 'table' and row.metadata or nil
            if type(md) == 'table' and md.director == run.id then gone[gid] = true end
        end
        for gid in pairs(gone) do
            if GroundItems.getById(gid) then GroundItems.deleteItem(gid) end
        end
    end
    -- Last, once what it made is gone: its players' games, and everyone else (the Director API).
    if not run.test then
        for s in pairs(run.players) do Director.tellPlayer(run, s, 'ended', { outcome = e.public, payout = math.floor(run.payout or 0) }) end
    end
    local fault = nil
    if run.faultNode then
        local n = run.graph.nodes[run.faultNode]
        fault = { id = run.faultNode, type = n and n.type or nil }
    end
    local vars = {}
    for k, v in pairs(run.vars or {}) do vars[k] = v end
    Director.announce('run:ended', { run = view, outcome = e.public, reason = reason, vars = vars,
                                     payout = math.floor(run.payout or 0), faultCard = fault,
                                     stopping = e.stopping }, run.test)
    -- When it's switched on: a new run once this one is over and what it made has gone, while the scenario is still on
    -- (Director.openRun asks: one switched off is refused). Not for one that ended before anyone joined it (it would
    -- end the same way again at once).
    if e.reopens then
        local sc = run.scenario
        SetTimeout(REOPEN_MS, function() Director.openRun(sc) end)
    elseif e.opened then
        say('^3scenario %s: its run ended before anyone joined it (%s): it starts again when it is switched off and on^0',
            tostring(run.scenario.id), tostring(reason or outcome))
    end
end

CoreStop.add(5, 'director: end the runs', function()
    R.abortAll('whip_core stopping')
end)

--- One player out of ONE run: off its band and out of its blips (map.blip keeps them by character, so
--- a relog as the same character would bring them back), their history row 'left', told, then out
--- (a run with nobody left ends). Logging out, disconnecting and RemovePlayerFromScenarioRun all come
--- through here.
---@param by string|nil  the resource that took them out (RemovePlayerFromScenarioRun)
local function leaveRun(run, src, why, by)
    DirectorBand.drop(run, src)   -- its objective and clocks off their screen
    DirectorTalk.drop(run, src)   -- the Talk points it offered them, and their conversation with it
    local cid = run.charOf and run.charOf[src]
    for id, b in pairs(run.blips or {}) do
        local people = {}
        for _, p in ipairs(b.people) do if p.charId ~= cid then people[#people + 1] = p end end
        b.people = people
        Blips.show(CORE, { people = people }, id, b.spec)
    end
    -- Their history says they left (not the run's outcome, which comes later, without them). Told
    -- BEFORE they are taken out, which can end the run (its last player) and so announce run:ended: a
    -- script hears the leave first, as it happened. The view is already the run without them.
    DirectorStore.playerLeft(run, src)
    if by then Director.event(run, nil, 'removed', src, ('taken out by %s: %s'):format(by, tostring(why))) end
    local others = 0
    for s in pairs(run.players) do if s ~= src then others = others + 1 end end
    local view = Director.view(run, src)
    if not run.test then Director.tellPlayer(run, src, 'left', { why = why }) end
    Director.announce('run:playerLeft', { run = view, source = src, charId = cid, why = why, by = by,
                                          runEnds = others == 0 and not run.always }, run.test)
    R.removePlayer(run, src, why)
    -- What the crew was given (a door, the safe, a prompt) is theirs no longer.
    Director.crewChanged(run)
    -- No longer one of its players: back on a character, they see its start point as everyone does.
    if run.scenario then refreshStart(run.scenario) end
end

-- A player gone is gone from every run they were in.
local function leave(src, why)
    local left = {}
    for _, run in ipairs(R.list()) do
        if run.players[src] then left[#left + 1] = run end
    end
    table.sort(left, function(a, b) return a.id < b.id end)
    for _, run in ipairs(left) do leaveRun(run, src, why) end
end

--- One player out of one run by its own rule (a Fail Condition set to take only them out: nodes_conditions.lua), as
--- RemovePlayerFromScenarioRun takes one out. The run goes on without them (or ends, with nobody left). What it
--- handed them goes back too, in a thread of its own (it writes their pockets): they stay online, and the run's end
--- only looks in its players' pockets.
function Director.takeOut(run, src, why)
    if not (run and run.status == 'running' and run.players[src]) then return end
    leaveRun(run, src, why)
    CreateThread(function()
        local ok, n, what = pcall(DirectorEffects.takeBack, run, src)
        if not ok then say('^1run %d: taking its items back from %s failed: %s^0', run.id, tostring(src), tostring(n))
        elseif n > 0 then NotifyPlayer(src, ('%s taken back: you are out of the job'):format(what or 'Its items'), 'info') end
    end)
end

-- At most this many players in a run (a script's `with`, AddPlayerToScenarioRun).
Director.MAX_CREW = 16

--- How many one of its runs takes, the starter included: its Team size (Settings). Its limit wherever
--- players come in: who joins at the start (a timer's or a script's list), Pick Team's slots,
--- AddPlayerToScenarioRun. A scenario saved before it had one takes MAX_CREW.
---@param sc table|nil  the scenario
---@return integer
function Director.teamSize(sc)
    local n = sc and sc.graph and type(sc.graph.settings) == 'table' and tonumber(sc.graph.settings.teamSize) or nil
    if not n or n ~= n then return Director.MAX_CREW end
    return math.max(1, math.min(Director.MAX_CREW, math.floor(n)))
end

--- What a card hands the crew follows the crew. A card that gives the run's
--- players something when it runs (a held door's access, a container's lock, its prompt, its guards'
--- targets, a goal's objective and marks) says here how to give it again; when a script puts a player
--- in or takes one out (AddPlayerToScenarioRun / RemovePlayerFromScenarioRun, or one leaves), it is
--- given again to the crew as it is now. So a joiner can open the vault, and one taken out cannot.
--- fn(players, charIds) answers false when its thing is gone (the hook goes); fn = nil stops it (a door
--- set back to anyone). Given again IN THE ORDER THEY WERE SET (set again: last), so a joiner's band
--- stacks the objectives as the crew's does: the newest on top.
function Director.followCrew(run, key, fn)
    if not run then return end
    run.crewHooks = run.crewHooks or {}
    run.crewSeq = (run.crewSeq or 0) + 1
    run.crewHooks[key] = fn and { fn = fn, seq = run.crewSeq } or nil
end

--- Give everything that follows the crew to the crew as it is now.
function Director.crewChanged(run)
    if not run.crewHooks or run.status ~= 'running' then return end
    local players = {}
    for s in pairs(run.players) do players[#players + 1] = s end
    table.sort(players)
    local charIds = Director.charIdsOf(run)
    local list = {}
    for k, h in pairs(run.crewHooks) do list[#list + 1] = { key = k, h = h } end
    table.sort(list, function(a, b) return a.h.seq < b.h.seq end)
    for _, e in ipairs(list) do
        -- (Still the same hook: an earlier one may have stopped or replaced it.)
        if run.crewHooks[e.key] == e.h then
            local ok, res = pcall(e.h.fn, players, charIds)
            if not ok then
                say('^1run %d: handing %s to its crew again failed: %s^0', run.id, tostring(e.key), tostring(res))
            elseif res == false and run.crewHooks[e.key] == e.h then
                run.crewHooks[e.key] = nil
            end
        end
    end
end

--- Take a player out of one run (RemovePlayerFromScenarioRun): what it handed them goes back first
--- (they stay online, so it is taken now, not at their next load), then they leave it. WAITS (the
--- take-back writes their pockets).
---@return boolean ok
---@return string|nil why
function Director.removePlayer(run, src, why, by)
    if not run or run.status ~= 'running' then return false, 'That run is not going' end
    if not run.players[src] then return false, 'They are not in that run' end
    local ok, n, what = pcall(DirectorEffects.takeBack, run, src)
    if not ok then say('^1run %d: taking its items back from %s failed: %s^0', run.id, tostring(src), tostring(n))
    elseif n > 0 then NotifyPlayer(src, ('%s taken back: you are out of the job'):format(what or 'Its items'), 'info') end
    if run.status ~= 'running' or not run.players[src] then return true end   -- (it ended while that waited)
    leaveRun(run, src, why or 'taken out', by)
    return true
end

--- Put a player into a run going now (AddPlayerToScenarioRun): one of its crew from here on, with the
--- crew's rights (its doors and containers, its payouts) and what it shows them from now on (its
--- blips; its band when a card next puts it up). Never into a builder's Test, never into a second run
--- of the same scenario, and told.
---@return boolean ok
---@return string|nil why
function Director.addPlayer(run, src, by)
    if not run or run.status ~= 'running' then return false, 'That run is not going' end
    if run.test then return false, 'That run is a builder\'s Test' end
    if run.players[src] then return false, 'They are already in that run' end
    local sc = run.scenario
    local ok, why = Director.eligible(sc, src, { they = true })
    if not ok then return false, why end
    -- Into a job that has begun (or one with no Scenario Run Started By Player: it began at its start), their cooldown
    -- is asked here: nowhere later would. One joining a lead-in is asked with the crew at Scenario Run Started By
    -- Player. (cooldownWho 'starter': a joiner never starts it, so never waits.)
    if not run.pre then
        local cooling = Director.coolingDown(sc, { players = { [src] = true }, starter = run.starter })
        if cooling then return false, ('They can do this job again in %d min'):format(cooling[1].mins) end
    end
    local p = Players[src]
    local n = 0
    for _ in pairs(run.players) do n = n + 1 end
    local cap = Director.teamSize(sc)
    if n >= cap then return false, ('That run is full (%d %s)'):format(cap, cap == 1 and 'player' or 'players') end
    R.addPlayer(run, src)
    run.charOf = run.charOf or {}
    run.charOf[src] = p.charId
    DirectorStore.playerJoined(run, src)
    Director.event(run, nil, 'joined', src, by and ('added by ' .. by) or nil)
    -- The run's marks for EVERYONE in it are theirs too now (a mark for one player stays that player's).
    for id, b in pairs(run.blips or {}) do
        if b.all then
            local has = false
            for _, q in ipairs(b.people) do if q.charId == p.charId then has = true end end
            if not has then
                b.people[#b.people + 1] = { charId = p.charId }
                Blips.show(CORE, { people = b.people }, id, b.spec)
            end
        end
    end
    -- And what the crew was given: the held door, the safe, its prompts, its guards' targets, its goals.
    Director.crewChanged(run)
    if sc then refreshStart(sc) end
    NotifyPlayer(src, ('You joined %s'):format(sc and sc.name or 'a job'), 'info')
    Director.tellPlayer(run, src, 'joined')
    Director.announce('run:playerJoined', { run = Director.view(run), source = src, charId = p.charId, by = by })
    return true
end

Character.onLife('logout', function(e) if e and e.source then leave(e.source, e.why or 'logout') end end)
AddEventHandler('playerDropped', function() leave(source, 'left') end)

--- A character coming on holds no run's items: nobody is in a run while they load (leaving takes them
--- out of it), so a stamped stack in their pockets is from a run that is over for them: they logged
--- out or disconnected mid-job, or whip_core restarted under it (its end skips pockets while saving).
Character.onLife('loaded', function(e)
    local src = e and e.source
    if not src then return end
    CreateThread(function()
        local names = DirectorEffects.takeBackStale(src)
        if #names > 0 then
            NotifyPlayer(src, ('%s taken back: that job is over'):format(table.concat(names, ', ')), 'info')
        end
    end)
end)

-- ============================================
-- Start-up: the store, then the scenarios that were on
-- ============================================
--
-- After whip_core is up, and never able to stop it: a store that cannot be built or read switches
-- the Director off (Director.off says why), and the rest of whip runs as before.

--- Switch a stored scenario on: at `rev`, or the revision that was on (its draft if none was).
---@param by number|nil  who did it (nil: the server, at start-up)
---@param rev number|nil
---@param opts table|nil  { onlyIfOff = true }: the server, and only if it is still off after the read
function Director.activateStored(key, by, rev, opts)
    local row = DirectorStore.get(key)
    if not row then return false, 'no such scenario' end
    -- A script switched it off (SwitchScenario): the server bringing it back (boot, its pack starting
    -- again: by = nil) leaves it off; a person switching it on is their choice, and forgets the script's.
    local sw = Director.scriptSwitched[key]
    if by == nil and sw and sw.on == false then return false, ('switched off by %s'):format(tostring(sw.by)) end
    -- A shipped one is on only while its pack runs (server/director/packs.lua).
    local mayOn, packWhy = DirectorPacks.mayActivate(key)
    if not mayOn then return false, packWhy end
    rev = rev or row.activeRev or row.draftRev
    local doc, why = DirectorStore.revision(key, rev)
    if not doc then return false, why end
    -- After the wait, asked again (house rule), when it is the server bringing it back (a boot, its cards
    -- arriving): a person may have switched it off, or on, while the revision was read.
    if by == nil then
        local now = DirectorStore.get(key)
        if not now or now.status ~= 'active' then return false, 'a person switched it off meanwhile' end
        -- (Its cards arriving brings back only one that is off: a person's switch-on meanwhile stands.)
        if opts and opts.onlyIfOff and Director.active[key] then return true end
    end
    -- Whose cards (server/director/cards_api.lua): brought back by the server
    -- (a boot, its cards' resource starting), it runs another resource's cards only from the resource a
    -- person switched it on with. A person switching it on accepts whoever provides them now.
    if by == nil then
        local moved = Director.cardsChangedHands(key, doc)
        if moved then return false, moved end
    end
    local ok, res = Director.activate(key, doc, { dbId = row.id, rev = rev, by = by })
    if not ok then
        -- Its cards' resource has not started yet: it comes back on by itself once they are all here.
        if by == nil then Director.waitForCards(key, doc) end
        return false, res
    end
    if row.status ~= 'active' or row.activeRev ~= rev then DirectorStore.setStatus(key, 'active', rev, by) end
    Director.stampCards(key, doc, by)
    return true, res
end

CoreStart.add('the Director', function()
    if not DirectorStore.ensureTables() then
        Director.off = 'its tables could not be made'
        say('^1the Director is OFF: %s (see above). The rest of whip runs as normal.^0', Director.off)
        return
    end
    -- Lore characters before any scenario is checked or back on: their cards name them.
    if DirectorLore.ensureTable() then
        local okLore, lwhy = DirectorLore.loadAll()
        if not okLore then say('^3lore characters are unavailable: %s^0', tostring(lwhy)) end
    else
        say('^3lore characters are unavailable: the director_lore tables could not be made^0')
    end
    local maxRun, why = DirectorStore.loadAll()
    if not maxRun then
        Director.off = 'its scenarios could not be read: ' .. tostring(why)
        say('^1the Director is OFF: %s. The rest of whip runs as normal.^0', Director.off)
        return
    end
    -- Run ids carry on from the highest ever handed out (kept as each run starts: a lead-in, an open run nobody joined
    -- and a test are never filed in the history), so a tag, a record or a live run's mark (fromRun) is never reused.
    R.seedIds(math.max(maxRun, GetResourceKvpInt(LAST_RUN_KVP) or 0))

    -- Shipped scenarios (server/director/packs.lua): what every running resource brings, read before
    -- the stored ones come back on, so a shipped one whose pack is not running stays off. A pack table
    -- that cannot be made or read leaves shipped scenarios unavailable; the rest of the Director runs.
    if DirectorPacks.ensureTable() then
        local okPacks, pwhy = DirectorPacks.loadAll()
        if okPacks then DirectorPacks.scanAll() else say('^3shipped scenarios are unavailable: %s^0', tostring(pwhy)) end
    else
        say('^3shipped scenarios are unavailable: the director_packs table could not be made^0')
    end

    -- Ground items a run placed and never cleaned up (the server stopped mid-run: a test's stamp, or a live run's own
    -- pile, drun), a standing item spot's from the start before (it is made again as its scenario comes back on), and a
    -- Dungeon car's key left on the ground (its car went with the last start: server/director/live.lua): found by their
    -- stamp. BEFORE any scenario is back on, so nothing of this start can have placed one yet.
    local ids = {}
    for id, row in pairs(GroundItems and GroundItems.cache or {}) do
        local md = type(row) == 'table' and row.metadata or nil
        if type(md) == 'table' and (md.director ~= nil or md.drun ~= nil or md.dstanding ~= nil or md.dlive ~= nil) then ids[#ids + 1] = id end
    end
    for _, id in ipairs(ids) do GroundItems.deleteItem(id) end
    if #ids > 0 then say('removed %d ground item(s) a run, a standing item spot or Dungeon Mode left behind', #ids) end

    -- Back on once a character has loaded: their standing things are NPCs, and an NPC made with nobody
    -- in the game loses its network id on Enhanced (Character.afterFirstLoad).
    Character.afterFirstLoad(function()
        -- Each on its own: one that throws is said, and the rest still come back on.
        for _, s in ipairs(DirectorStore.list()) do
            if s.status == 'active' then
                local ran, ok, res = pcall(Director.activateStored, s.key)
                if not ran then
                    say('^1scenario %s did not come back on: %s^0', s.key, tostring(ok))
                elseif not ok then
                    say('^3scenario %s did not come back on: %s^0', s.key, Director.whyNotOn(res))
                end
            end
        end
    end)
end)

-- (The /director dev commands: commands.lua.)

