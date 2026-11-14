-- The Director API: what other resources may ask about runs and scenarios.
--   * Views: a run, to anyone outside, is a DirectorRunView, a plain copy made when asked (never the run itself).
--     Every public event (main.lua, Director.announce) and every export below answers in it. A scenario is a
--     DirectorScenarioView answered from memory, so asking never waits on the database.
--   * The information exports (types/server.lua has each one's shape).
--   * What each player's own game is told about their runs (joined, objective, left, ended), for a phone's job
--     screen or a HUD: client/director_runs.lua turns it into local events and GetMyRuns. A push to that player only.
-- Test runs are left out of every answer unless `{ tests = true }` is asked for, and their players are told nothing.

local R = DirectorRuntime

-- ============================================
-- Views
-- ============================================

--- A copy of plain data (strings, numbers, booleans and tables of them), at most 8 deep.
local function plain(v) return DirectorKit.plain(v) end

--- A run as other resources see it.
---@param run table
---@param except number|nil  a player to leave out (one who is leaving it)
---@return table DirectorRunView
function Director.view(run, except)
    local graph = run.graph or {}
    local settings = type(graph.settings) == 'table' and graph.settings or {}
    -- An ended run (run:ended's view) is measured to its end, has no deadline and shows nobody anything.
    local ended = run.status ~= 'running'
    local now = (ended and run.endedAt) or GetGameTimer()
    local secs = math.max(0, math.floor((now - (run.startedAt or now)) / 1000))
    local srcs = {}
    for s in pairs(run.players or {}) do if s ~= except then srcs[#srcs + 1] = s end end
    table.sort(srcs)
    local players, objectives = {}, {}
    for _, s in ipairs(srcs) do
        local p = Players[s]
        players[#players + 1] = { source = s, charId = (run.charOf and run.charOf[s]) or (p and p.charId) or nil,
                                  name = p and p.fullName or nil }
        local text, countdown = DirectorBand.current(run, s)
        if text and not ended then objectives[#objectives + 1] = { source = s, text = text, countdown = countdown } end
    end
    local things = {}
    for wid, h in pairs(run.world or {}) do
        if type(h) == 'table' then
            local w = type(graph.world) == 'table' and graph.world[wid] or nil
            things[wid] = { kind = w and w.kind or nil, netId = h.netId, npcId = h.npcId, vehicleId = h.vehicleId,
                            containerId = h.containerId, groundId = h.groundId, doorId = h.doorId,
                            npcs = type(h.group) == 'table' and plain(h.group) or nil }
        end
    end
    local sc = run.scenario
    -- Where it happens, at THIS run's place when it was started with its own (opts.places).
    local where = DirectorGraph.whereOf(graph)
    local moved = where and run.places and run.places[where.world]
    if moved then where.coords = { x = moved.x, y = moved.y, z = moved.z } end
    return {
        id = run.id, tag = run.tag, scenario = run.scenarioId, name = sc and sc.name or run.scenarioId, rev = run.rev,
        test = run.test == true, kinds = (DirectorGraph.kindsOf(settings)), where = where,
        players = players, starter = run.starter, startedAt = os.time() - secs, seconds = secs,
        endsIn = (not ended and run.deadlineAt) and math.max(0, math.floor((run.deadlineAt - now) / 1000)) or nil,
        vars = plain(run.vars) or {}, objectives = objectives, things = things,
        -- The variant it plays, when its scenario has more than one.
        variant = run.variant and { id = run.variant, name = run.variantName } or nil,
    }
end

--- What a scenario says about itself: the switched-on revision when it is on, else its draft.
local function summaryOf(key)
    local sc = Director.active[key]
    if sc then
        sc.summary = sc.summary or DirectorStore.summarize(sc.doc)
        return sc.summary
    end
    return DirectorStore.summary(key)
end

--- How many runs of it are going (tests left out).
local function liveRuns(key)
    local n = 0
    for _, run in ipairs(R.list()) do
        if run.scenarioId == key and not run.test then n = n + 1 end
    end
    return n
end

--- A scenario as other resources see it. `full`: with its cards, placed things and variables.
---@return table|nil DirectorScenarioView
local function scenarioView(key, full)
    local row = DirectorStore.get(key)
    local sc = Director.active[key]
    if not row and not sc then return nil end
    local sum = summaryOf(key) or {}
    local v = {
        key = key, name = (sc and sc.name) or (row and row.name) or sum.name or key,
        description = sum.description or (row and row.description) or nil,
        kinds = sum.kinds or {}, where = sum.where, on = sc ~= nil, rev = sc and sc.rev or nil,
        draftRev = row and row.draftRev or nil, startMode = sum.startMode or 'admin',
        -- 'db' (made here), 'pack:<resource>' (shipped, read-only), 'file' (/director load: not stored)
        source = row and row.source or 'file', runs = liveRuns(key),
    }
    if full then
        v.cards, v.world, v.vars = plain(sum.cards) or {}, plain(sum.world) or {}, plain(sum.vars) or {}
    end
    -- Its variants (more than one: { id, name }).
    if type(sum.variants) == 'table' and #sum.variants > 1 then v.variants = plain(sum.variants) end
    return v
end

-- ============================================
-- Each player's own game
-- ============================================

--- Tell one player's game about a run they are in: 'joined', 'updated' (what their band says),
--- 'left', 'ended'. Test runs tell nothing. An 'updated' that says what it said last time is not sent.
---@param extra table|nil  'left': { why }; 'ended': { outcome, payout }
function Director.tellPlayer(run, src, op, extra)
    if run.test or type(src) ~= 'number' then return end
    local text, countdown, endsAt = DirectorBand.current(run, src)
    if op == 'updated' then
        -- When the clock ENDS (its own time), not how long is left: later, the same clock is the same band.
        local sig = tostring(text) .. '|' .. tostring(endsAt)
        run.toldBand = run.toldBand or {}
        if run.toldBand[src] == sig then return end
        run.toldBand[src] = sig
    end
    local info = { id = run.id, scenario = run.scenarioId, name = run.scenario and run.scenario.name or run.scenarioId,
                   objective = text, countdown = countdown }
    TriggerClientEvent('whip_core:client:directorRun', src, op, info, plain(extra))
end

-- ============================================
-- Information exports (no waiting, unless said)
-- ============================================

local function wantsTests(opts) return type(opts) == 'table' and opts.tests == true end

--- The player a `who` names (a server id, or { charId = n } while online), or nil and why.
local function sourceOf(who)
    local charId, src = WhoIs(who)
    if not charId then return nil, src end
    if not src then return nil, 'That character is not online' end
    return src
end

--- GetScenarioRun(runId, opts?) -> DirectorRunView | false, why
exports('GetScenarioRun', function(runId, opts)
    local run = R.get(math.tointeger(tonumber(runId)) or -1)
    if not run or (run.test and not wantsTests(opts)) then return false, 'No run with that id is going' end
    return Director.view(run)
end)

--- ListScenarioRuns(filter?) -> { DirectorRunView, ... }   filter: { scenario?, player?, kind?, tests? }
exports('ListScenarioRuns', function(filter)
    filter = type(filter) == 'table' and filter or {}
    local who = filter.player ~= nil and sourceOf(filter.player) or nil
    if filter.player ~= nil and not who then return {} end
    local kind = type(filter.kind) == 'string' and filter.kind:lower() or nil
    local out = {}
    for _, run in ipairs(R.list()) do
        local ok = (not run.test or filter.tests == true)
            and (filter.scenario == nil or run.scenarioId == filter.scenario)
            and (who == nil or run.players[who] == true)
        if ok and kind then
            ok = false
            for _, k in ipairs((DirectorGraph.kindsOf(run.graph.settings))) do if k == kind then ok = true break end end
        end
        if ok then out[#out + 1] = Director.view(run) end
    end
    return out
end)

--- GetPlayerScenarioRuns(who, opts?) -> { DirectorRunView, ... }
exports('GetPlayerScenarioRuns', function(who, opts)
    local src = sourceOf(who)
    if not src then return {} end
    local out = {}
    for _, run in ipairs(R.list()) do
        if run.players[src] and (not run.test or wantsTests(opts)) then out[#out + 1] = Director.view(run) end
    end
    return out
end)

--- IsPlayerInScenarioRun(who, key?, opts?) -> boolean   (key: of that scenario; none: of any)
exports('IsPlayerInScenarioRun', function(who, key, opts)
    local src = sourceOf(who)
    if not src then return false end
    for _, run in ipairs(R.list()) do
        if run.players[src] and (key == nil or run.scenarioId == key) and (not run.test or wantsTests(opts)) then return true end
    end
    return false
end)

--- GetScenarioRunOf({ netId | vehicleId | npcId | tag }, opts?) -> DirectorRunView | false, why
--- Which run a car, an NPC or a tag belongs to (a police tracker on a getaway car).
exports('GetScenarioRunOf', function(ref, opts)
    if type(ref) ~= 'table' then return false, 'Ask with { netId = n }, { vehicleId = n }, { npcId = n } or { tag = text }' end
    local netId, vehicleId, npcId, tag = tonumber(ref.netId), tonumber(ref.vehicleId), tonumber(ref.npcId), ref.tag
    -- A netId is the entity there NOW: what whip knows it as (its NPC, its car), read once. A handle's
    -- own netId is never trusted alone: it outlives the ped or car, and FiveM gives netIds out again.
    local rawNet
    if netId then
        local ent = NetworkGetEntityFromNetworkId(netId)
        if not ent or ent == 0 or not DoesEntityExist(ent) then return false, 'That is not part of a run going now' end
        npcId = npcId or (Npcs.by('netId', netId) or nil)
        vehicleId = vehicleId or (Vehicles.getEntityVehicleId(ent) or nil)
        rawNet = netId
    end
    for _, run in ipairs(R.list()) do
        if not run.test or wantsTests(opts) then
            if tag ~= nil and run.tag == tag then return Director.view(run) end
            for _, h in pairs(run.world or {}) do
                if type(h) == 'table' then
                    if vehicleId and h.vehicleId == vehicleId then return Director.view(run) end
                    for _, id in ipairs(npcId and DirectorNodes.npcIds(h) or {}) do
                        if id == npcId then return Director.view(run) end
                    end
                    -- (Only a handle with no id of its own goes by its netId: one that exists, as above.)
                    if rawNet and h.netId == rawNet and h.npcId == nil and h.vehicleId == nil then return Director.view(run) end
                end
            end
        end
    end
    return false, 'That is not part of a run going now'
end)

--- CanStartScenarioRun(key, who) -> true | false, why: would StartScenarioRun start one for them now?
--- The same checks, nothing started (a phone app greys out the jobs a player cannot take).
exports('CanStartScenarioRun', function(key, who)
    if Director.off then return false, 'The Director is off: ' .. tostring(Director.off) end
    local sc = type(key) == 'string' and Director.active[key] or nil
    if not sc then return false, 'that scenario is not switched on' end
    local start = sc.graph.settings.start
    local mode = type(start) == 'table' and start.mode or nil
    if mode ~= 'script' and mode ~= 'enabled' then
        return false, 'that scenario does not start from a script (its Scenario Enabled card: It starts)'
    end
    local src, why = sourceOf(who)
    if not src then return false, why end
    -- Who may be in one: the start's own answer (main.lua Director.eligible), never a copy of it.
    local ok, ewhy = Director.eligible(sc, src, { they = true })
    if not ok then return false, ewhy end
    -- Cooling down from it: a job with no Scenario Run Started By Player is refused at its start (Director.startRun), as here
    if not R.hasBegin(sc.graph) then
        local cooling = Director.coolingDown(sc, { players = { [src] = true }, starter = src })
        if cooling then return false, ('They can do this job again in %d min'):format(cooling[1].mins) end
    end
    -- A card of another resource it needs is not here (its resource stopped): a start would refuse it.
    local missing = Director.cardsMissing and Director.cardsMissing(sc)
    if missing then return false, missing end
    -- When it's switched on: its one run waits for a player, free while nobody has taken it (main.lua Director.claim).
    if mode == 'enabled' then
        local waiting = Director.openRunOf(sc)
        if waiting and not waiting.open then return false, 'Someone is doing this already' end
        return true
    end
    -- (With variants: one run each, and one of them free.)
    if Director.runsOf(sc) >= Director.maxRuns(sc) or not Director.pickVariant(sc, true) then
        return false, 'this scenario is already running'
    end
    if #R.list() >= R.LIMITS.runs then return false, 'too many scenarios are running' end
    return true
end)

--- GetScenario(key) -> DirectorScenarioView (with cards, world, vars) | false, why
exports('GetScenario', function(key)
    local v = type(key) == 'string' and scenarioView(key, true) or nil
    if not v then return false, 'No scenario called ' .. tostring(key) end
    return v
end)

--- ListScenarios(filter?) -> { DirectorScenarioView (short), ... }   filter: { on?, kind?, startMode? }
exports('ListScenarios', function(filter)
    filter = type(filter) == 'table' and filter or {}
    local kind = type(filter.kind) == 'string' and filter.kind:lower() or nil
    local keys, seen = {}, {}
    for _, row in ipairs(DirectorStore.list()) do keys[#keys + 1] = row.key seen[row.key] = true end
    for key in pairs(Director.active) do if not seen[key] then keys[#keys + 1] = key end end
    table.sort(keys)
    local out = {}
    for _, key in ipairs(keys) do
        local v = scenarioView(key, false)
        local ok = v ~= nil and (filter.on == nil or v.on == (filter.on == true))
            and (filter.startMode == nil or v.startMode == filter.startMode)
        if v and ok and kind then
            ok = false
            for _, k in ipairs(v.kinds) do if k == kind then ok = true break end end
        end
        if ok then out[#out + 1] = v end
    end
    return out
end)

--- GetScenarioStats(key) -> { runs, succeeded, stopped, lastAt } | false, why   WAITS on the database
--- (call it from a thread). Test runs left out; `stopped` is called off, stopped or cut short.
exports('GetScenarioStats', function(key)
    local row = type(key) == 'string' and DirectorStore.get(key) or nil
    if not row then return false, 'No stored scenario called ' .. tostring(key) end
    local s, why = DirectorStore.statsOf(row.id)
    if not s then return false, why end
    return { runs = s.runs, succeeded = s.succeeded, stopped = s.aborted,
             lastAt = s.lastAt and EpochSeconds and EpochSeconds(s.lastAt) or nil }
end)

-- ============================================
-- Steering runs
-- ============================================
--
-- Server scripts are trusted code, as for every whip export: any may end a run, add or
-- remove its crew, set its variables and send it events, and every end, add and remove is written into
-- the run's history with the resource's name. A builder's Test is refused (EndScenarioRun alone takes
-- one: a script ending what it started there). Variable writes and events are not written down (a
-- score set every few seconds would push the players' own interactions out of the history).

local MAX_TEXT = 200

local function checkVar(graph, name, v)
    local decl = type(name) == 'string' and graph.vars[name] or nil
    if not decl then return false, ('"%s" is not one of this scenario\'s variables'):format(tostring(name)) end
    local t = decl.type or 'text'
    if t == 'number' then
        if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return false, name .. ' is a number' end
    elseif t == 'bool' then
        if type(v) ~= 'boolean' then return false, name .. ' is true or false' end
    else
        if type(v) ~= 'string' then return false, name .. ' is text' end
        if #v > MAX_TEXT then return false, ('%s is at most %d characters'):format(name, MAX_TEXT) end
    end
    return true, v
end
--- One variable's value against its declaration: true, the value | false, why (a card's setVar too).
Director.checkVar = checkVar

--- A start's variables (opts.vars), checked against the scenario's: a copy, or false and why.
function Director.checkVars(graph, vars)
    if type(vars) ~= 'table' then return false, 'opts.vars is a table: { name = value }' end
    local out = {}
    for name, v in pairs(vars) do
        local ok, val = checkVar(graph, name, v)
        if not ok then return false, val end
        out[name] = val
    end
    return out
end

-- What a run can be told is somewhere else: what its cards make (an NPC, a car, an item, a container)
-- and its spots. Not a standing thing (there before any run), a door (it is where the map has it) or a
-- prop (its set is the scenario's).
local PLACEABLE = { npc = true, vehicle = true, groundItem = true, container = true, spot = true }

--- A place as a script may give it: a table, a vector3 / vector4 (FiveM's), or { coords = either }.
local function isPoint(v)
    local t = type(v)
    return t == 'table' or t == 'vector3' or t == 'vector4'
end

--- A start's places (opts.places), checked like the World tab: { [placedThingId] = { x, y, z, heading,
--- interior? } } (or a vector3 / vector4), or false and why. `interior = true`: the place is inside an
--- MLO (what it makes waits for the interior); the World tab's own answer is for its own spot only.
function Director.checkPlaces(graph, places)
    if type(places) ~= 'table' then return false, 'opts.places is a table: { [placedThingId] = { x, y, z, heading } }' end
    local out, n = {}, 0
    for wid, at in pairs(places) do
        local w = type(wid) == 'string' and graph.world[wid] or nil
        if not w then return false, ('"%s" is not one of its placed things'):format(tostring(wid)) end
        if w.layer == 'standing' then return false, ('"%s" is there before any run (Standing): it cannot move for one'):format(wid) end
        if not PLACEABLE[w.kind] then return false, ('"%s" is a %s: it stays where it was placed'):format(wid, tostring(w.kind)) end
        local c = isPoint(at) and ((type(at) == 'table' and isPoint(at.coords)) and at.coords or at) or nil
        local x, y, z = tonumber(c and c.x), tonumber(c and c.y), tonumber(c and c.z)
        local fine = x and y and z and x == x and y == y and z == z
            and math.abs(x) <= 20000 and math.abs(y) <= 20000 and z >= -500 and z <= 3000
        if not fine then return false, ('"%s": a place is { x, y, z, heading } on the map'):format(wid) end
        if type(at) == 'table' and at.interior ~= nil and type(at.interior) ~= 'boolean' then
            return false, ('"%s": interior is true or false'):format(wid)
        end
        local h = tonumber(type(at) == 'table' and at.heading or nil)
        if h == nil and type(c) == 'table' then h = tonumber(c.heading) end
        if h == nil and type(c) == 'vector4' then h = tonumber(c.w) end
        h = h or 0.0
        if h ~= h or h == math.huge or h == -math.huge then h = 0.0 end
        out[wid] = { x = x, y = y, z = z, heading = h % 360, interior = type(at) == 'table' and at.interior == true or nil }
        n = n + 1
        if n > 64 then return false, 'at most 64 places' end
    end
    return out
end

--- The run a control export names, or nil and why. `allowTest`: EndScenarioRun's (it ends tests too).
local function runFor(runId, allowTest)
    local run = R.get(math.tointeger(tonumber(runId)) or -1)
    if not run then return nil, 'No run with that id is going' end
    if run.test and not allowTest then return nil, 'That run is a builder\'s Test' end
    return run
end

--- EndScenarioRun(runId, 'succeeded' | 'failed' | 'calledOff', reason?) -> true | false, why
--- As a Succeed, Fail or Call Off card would end it (calledOff: no result, nobody told).
exports('EndScenarioRun', function(runId, outcome, reason)
    local by = Registry.caller()
    local run, why = runFor(runId, true)
    if not run then return false, why end
    if outcome ~= 'succeeded' and outcome ~= 'failed' and outcome ~= 'calledOff' then
        return false, "outcome is 'succeeded', 'failed' or 'calledOff'"
    end
    reason = type(reason) == 'string' and DirectorKit.cut(reason, 120) or nil
    Director.event(run, nil, 'ended', nil, ('ended by %s: %s%s'):format(by, outcome, reason and (' (' .. reason .. ')') or ''))
    -- The resource's name rides with the reason into the run's own record (its event row can be past
    -- the history's cap of 200).
    if not R.finishRun(run.id, outcome, reason and ('%s (by %s)'):format(reason, by) or ('ended by ' .. by)) then
        return false, 'That run is not going'
    end
    return true
end)

--- AddPlayerToScenarioRun(runId, who) -> true | false, why. CREW: the run's rights are theirs. A run waiting for its
--- first player (one that starts When it's switched on) is CLAIMED by them, as a press on its Talk would: its job begins,
--- they are its starter, and nobody else can take it.
exports('AddPlayerToScenarioRun', function(runId, who)
    local by = Registry.caller()
    local run, why = runFor(runId, false)
    if not run then return false, why end
    local src, swhy = sourceOf(who)
    if not src then return false, swhy end
    if run.open then return Director.claim(run, src) end
    return Director.addPlayer(run, src, by)
end)

--- RemovePlayerFromScenarioRun(runId, who, why?) -> true | false, why. WAITS (what the run handed them
--- is taken back first): call it from a thread.
exports('RemovePlayerFromScenarioRun', function(runId, who, why)
    local by = Registry.caller()
    local run, rwhy = runFor(runId, false)
    if not run then return false, rwhy end
    local src, swhy = sourceOf(who)
    if not src then return false, swhy end
    return Director.removePlayer(run, src, type(why) == 'string' and DirectorKit.cut(why, 120) or nil, by)
end)

--- GetScenarioRunVar(runId, name, opts?) -> true, value | false, why
--- (TRUE FIRST: a variable can hold false or nothing, and an answer is cut at its first nil.)
exports('GetScenarioRunVar', function(runId, name, opts)
    local run = R.get(math.tointeger(tonumber(runId)) or -1)
    if not run or (run.test and not wantsTests(opts)) then return false, 'No run with that id is going' end
    if type(name) ~= 'string' or not run.graph.vars[name] then
        return false, ('"%s" is not one of its variables'):format(tostring(name))
    end
    return true, run.vars[name]
end)

--- SetScenarioRunVar(runId, name, value) -> true | false, why   (typed: the scenario's own types)
exports('SetScenarioRunVar', function(runId, name, value)
    local run, why = runFor(runId, false)
    if not run then return false, why end
    local ok, v = checkVar(run.graph, name, value)
    if not ok then return false, v end
    R.setVar(run, name, v)
    return true
end)

-- ============================================
-- Telling runs something (SendDirectorEvent; the Wait for Script Event card hears it)
-- ============================================
--
-- AN EVENT IS NAMED IN THE SENDER'S OWN NAMESPACE: 'police.backupArrived'. The first running resource
-- to send in a namespace has it (a registry, so it is free again when that resource stops); another
-- is refused with its owner's name, and whip_core's own (the cards' groups, the events it bridges) are
-- nobody's. One namespace for cards and events: DirectorNodes.claimSpace, so the resource
-- whose cards are police.* is the one whose events are. A run's builder types the name on the card,
-- so which script's event it waits for is theirs to decide. Rate-limited at the export, so a chatty
-- script is told 'too often' instead of its runs faulting as runaways. What a script sends is its
-- word: a card that pays on one checks the truth first.

local MAX_SENDS = 20       -- per sender and name, a second
local MAX_SENDS_ALL = 60   -- per sender, a second, every name together
local sends, sendsAt = {}, 0

--- A small copy of what a script sends: 4 deep, 50 keys a table, text cut at 500, a vector as { x, y, z, heading }.
local function small(v) return DirectorKit.plain(v, { depth = 4, keys = 50, text = 500 }) end

--- Send `name` to the runs waiting for it. Answers how many heard it (and why not, when a named run is
--- not going). `test`: for builders' Tests only (/director send); a real event never reaches a Test.
---@return number heard
---@return string|nil why
function Director.sendEvent(name, payload, opts, by, test)
    local trigger = { event = name, sender = by, test = test == true, data = small(payload) or {},
                      source = type(payload) == 'table' and math.tointeger(tonumber(payload.source)) or nil }
    local only
    if type(opts) == 'table' and opts.runId ~= nil then
        only = R.get(math.tointeger(tonumber(opts.runId)) or -1)
        -- A builder's Test is no script's to find: as if it were not there (it is not, to them).
        if not only or (only.test and not test) then return 0, 'No run with that id is going' end
        trigger.runId = only.id
    end
    return R.emit('script.event', trigger, only)
end

--- SendDirectorEvent(name, payload?, opts?) -> true, heardBy | false, why
---   name     '<your namespace>.<name>' ('police.backupArrived')
---   payload  a table; payload.source (a server id) is who it is about: the card acts for them when they
---            are one of that run's players
---   opts     { runId }: only that run hears it
exports('SendDirectorEvent', function(name, payload, opts)
    local by = Registry.caller()
    if type(name) ~= 'string' or #name > 64 or not name:match('^[%a][%w_]*%.[%a][%w_.]*$') then
        return false, 'an event is named "<yours>.<name>", like police.backupArrived'
    end
    if payload ~= nil and type(payload) ~= 'table' then return false, 'payload is a table' end
    local ok, owner = DirectorNodes.claimSpace(by, name:match('^([^.]+)'))
    if not ok then return false, owner end
    local now = math.floor(GetGameTimer() / 1000)
    if now ~= sendsAt then sends, sendsAt = {}, now end
    local key = by .. '\0' .. name
    sends[key] = (sends[key] or 0) + 1
    sends[by] = (sends[by] or 0) + 1   -- and all of a sender's, whatever the names
    local refused = (sends[key] > MAX_SENDS and ('too often: at most %d of one event a second'):format(MAX_SENDS))
        or (sends[by] > MAX_SENDS_ALL and ('too often: at most %d events a second from one resource'):format(MAX_SENDS_ALL)) or nil
    local heard, why = 0, refused
    if not refused then heard, why = Director.sendEvent(name, payload, opts, by, false) end
    -- /director events (main.lua): each one in the server console, while it is on. A refusal for too
    -- many is printed once a second (the first over), never a line for each of a runaway script's.
    local firstOver = sends[key] == MAX_SENDS + 1 or sends[by] == MAX_SENDS_ALL + 1
    if Director.watchEvents and (not refused or firstOver) then
        local about = type(payload) == 'table' and math.tointeger(tonumber(payload.source)) or nil
        local okJ, data = pcall(json.encode, small(payload) or {})
        data = okJ and data or '?'
        print(('[whip_core:director] event %s from %s%s%s: %s %s'):format(name, by, about and (' about player ' .. about) or '',
            type(opts) == 'table' and opts.runId and (' to run ' .. tostring(opts.runId)) or '',
            why and ('refused, ' .. why .. (refused and ' (the rest this second are not printed)' or '')) or (heard > 0 and ('heard by %d card%s'):format(heard, heard == 1 and '' or 's') or 'nothing was waiting for it'),
            #data > 160 and (DirectorKit.cut(data, 160) .. '...') or data))
    end
    if why then return false, why end
    return true, heard
end)

--- SwitchScenario(key, on, why?) -> true | false, why   WAITS (switching on reads the revision)
--- Only a scenario whose Settings say "Scripts may switch it on and off"; on again only at the revision a
--- person last switched on; in memory only (a reboot puts back what a person chose).
exports('SwitchScenario', function(key, on, why)
    local by = Registry.caller()
    if type(key) ~= 'string' then return false, 'key is the scenario\'s key' end
    -- Never read "not true" as off: switching off calls off every run of it going now.
    if type(on) ~= 'boolean' then return false, 'on is true or false' end
    if Director.off then return false, 'The Director is off: ' .. tostring(Director.off) end
    return Director.switchByScript(key, on == true, type(why) == 'string' and DirectorKit.cut(why, 120) or nil, by)
end)

--- CheckDirectorScenario(doc) -> ok, problems: what the editor's Check says of a document, for
--- authors and tools. problems = { { severity = 'error' | 'warning', node?, pin?, message } }.
exports('CheckDirectorScenario', function(doc)
    if type(doc) ~= 'table' then return false, { { severity = 'error', message = 'a scenario is a document (a table), as the editor saves it' } } end
    local ok, passes, problems = pcall(DirectorGraph.check, doc)
    if not ok then return false, { { severity = 'error', message = 'it could not be checked: ' .. tostring(passes) } } end
    return passes == true, plain(problems) or {}
end)

--- ListDirectorCards(filter?) -> { { type, title, desc, category, owner, inputs, outputs, labels, props }, ... }
--- filter: { category?, owner? }
exports('ListDirectorCards', function(filter)
    filter = type(filter) == 'table' and filter or {}
    local out = {}
    for _, c in ipairs(DirectorNodes.wire()) do
        if (filter.category == nil or c.category == filter.category) and (filter.owner == nil or c.owner == filter.owner) then
            out[#out + 1] = c
        end
    end
    return out
end)
