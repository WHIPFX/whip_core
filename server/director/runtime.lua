-- Director runtime: runs a compiled scenario graph. A run is one play of one scenario revision (its players,
-- variables, what it has made, where it is in the graph); many go at once, each an object, never a thread.
--   * A pulse is "enter card X at input pin P", carrying the trigger (who started this branch). Each run has a queue.
--   * An instant card (If, Set Variable) runs and names the output pins to follow; their pulses go to the front.
--   * A latent card (Wait, Spawn, Dialog) opens an activation and registers waits: a timer, an event, or a call
--     (a thread running something that yields). The first wait to fire wins and ends the activation.
--   * An event card (Scenario Enabled, NPC Killed) has no inputs and listens for the whole run.
-- One scheduler pass steps every run round-robin under hard limits (unbounded code on the server thread stops the server):
--   chain    500 cards in a row without a real pause faults the run (a wait answering within 100 ms, or an event the
--            run fired itself, does not reset the count)
--   burst    2000 cards without the queue ever emptying faults the run
--   perRun   100 cards per run per pass; perPass 1000 in total; about 2 ms of wall time
-- A card's code runs in its own coroutine: waiting inside the pass faults the run, so anything that waits goes in ctx:call.
-- A run ends on Succeed, Fail, a fault, an abort, the last player leaving, its deadline (settings.maxRunSec), or
-- having nothing left to wait for. Ports.onEnd (the tag release) runs at once.
-- Lead-in: a scenario with a Scenario Run Started By Player card plays what follows Scenario Enabled first. Until the
-- run reaches that card nothing it does counts: it ends quietly as called off. It has L.preSec to get there.
-- An open run (opts.open, a scenario that starts when switched on) starts with nobody in it, as a lead-in with no
-- time limit, until its first player joins.
-- Side effects reach the world only through ports, so the test harness can drive every rule with a fake clock.

DirectorRuntime = {
    LIMITS = {
        chain = 500, burst = 2000, perRun = 100, perPass = 1000, passMs = 2.0, runs = 64, trace = 200,
        quickMs = 100,                 -- a wait answered faster than this counts towards the chain
        resumesPerSec = 100,           -- a run woken more often than this in one second is a loop
        minWaitMs = 50, maxWaitMs = 7 * 24 * 3600 * 1000,
        maxRunSec = 3600,              -- a run's default deadline (settings.maxRunSec; 0 = none)
        preSec = 300,                  -- a lead-in's time to reach Scenario Run Started By Player (then it ends quietly)
        afterSec = 120,                -- an After card's chain's time, once the run has failed or succeeded
    },
    -- The longest the pass sleeps while any run exists: what comes from outside (an event, a call's answer, a run
    -- started) wakes it at once (wake), and a timer or a deadline sets its own sleep; this is only the net under them.
    -- (It was 100: ten passes a second for ever while a switched-on scenario's run waited for its first player.)
    IDLE_MS = 1000,
    SLEEP_MS = 5000,   -- ...and while none does (a run starting wakes it: R.start, and main.lua's wokenPass)
    MIN_MS = 10,       -- the shortest sleep for a timer (0 is only for queued work)
}
local R = DirectorRuntime
local L = R.LIMITS

local Ports = {
    now = function() return GetGameTimer() end,
    clock = os.clock,
    thread = function(fn) CreateThread(fn) end,                    -- call threads: next tick is fine
    threadNow = function(fn) Citizen.CreateThreadNow(fn) end,      -- end hooks: must run even in a stop
    wake = nil,        -- fn(): run a pass soon (SetTimeout(0, ...)); nil = the Every loop's own pace
    onEnd = nil,       -- fn(run, outcome, reason): release what the run made (its tag)
    broken = nil,      -- fn(run, nodeId, src, reason, onlyThem): a Fail Condition's rule broken (R.broken), before it acts
    takeOut = nil,     -- fn(run, src, why): one player out of the run, what it handed them going back; nil = R.removePlayer
    log = function(msg) print('[whip_core:director] ' .. msg) end,
}

--- Swap the side effects (the harness, and the Director's start-up wiring).
---@param p table
function R.setPorts(p)
    for k, v in pairs(p) do Ports[k] = v end
end

local runs = {}          -- [runId] = run, running runs only
local order = {}         -- run ids in start order, for the round-robin
local rr = 0
local nextRunId = 0
local nextWaitId = 0
local heap = {}          -- timer waits, a min-heap on (at, id)
local eventWaits = {}    -- [event name] = { wait, ... } in creation order
local holds = {}         -- [wait id] = a hold: answered from outside (R.answer), by another resource's card
local dirtyEvents = false
local bridged = { ['scenario.started'] = true, ['player.left'] = true }
local passing, wakeAsked = false, false

-- ============================================
-- Small parts: deque, heap, copies, the guarded call
-- ============================================

local function newDeque() return { first = 1, last = 0 } end
local function pushBack(q, v) q.last = q.last + 1; q[q.last] = v end
local function pushFront(q, v) q.first = q.first - 1; q[q.first] = v end
local function popFront(q)
    if q.first > q.last then return nil end
    local v = q[q.first]
    q[q.first] = nil
    q.first = q.first + 1
    return v
end
local function dequeEmpty(q) return q.first > q.last end

local function less(a, b) return a.at < b.at or (a.at == b.at and a.id < b.id) end

local function heapPush(w)
    heap[#heap + 1] = w
    local i = #heap
    while i > 1 do
        local p = i // 2
        if less(heap[i], heap[p]) then heap[i], heap[p] = heap[p], heap[i]; i = p else break end
    end
end

local function heapPop()
    local top = heap[1]
    local last = heap[#heap]
    heap[#heap] = nil
    if #heap > 0 then
        heap[1] = last
        local i = 1
        while true do
            local l, r, s = i * 2, i * 2 + 1, i
            if l <= #heap and less(heap[l], heap[s]) then s = l end
            if r <= #heap and less(heap[r], heap[s]) then s = r end
            if s == i then break end
            heap[i], heap[s] = heap[s], heap[i]
            i = s
        end
    end
    return top
end

local function compactTimers()
    local live = {}
    for _, w in ipairs(heap) do if not w.dead then live[#live + 1] = w end end
    heap = {}
    for _, w in ipairs(live) do heapPush(w) end
end

local function compactEvents()
    for name, list in pairs(eventWaits) do
        local live = {}
        for _, w in ipairs(list) do if not w.dead then live[#live + 1] = w end end
        eventWaits[name] = #live > 0 and live or nil
    end
    dirtyEvents = false
end

local function deepCopy(v, depth)
    if type(v) ~= 'table' then return v end
    depth = (depth or 0) + 1
    if depth > 16 then return nil end
    local out = {}
    for k, x in pairs(v) do out[k] = deepCopy(x, depth) end
    return out
end

--- Run card code so that a WAIT inside it is caught instead of stalling whoever called it.
---@return boolean ok
---@return any res   what the card answered, or the error
---@return any data
local function runGuarded(fn, ...)
    local co = coroutine.create(fn)
    local ok, a, b = coroutine.resume(co, ...)
    if coroutine.status(co) ~= 'dead' then
        pcall(coroutine.close, co)
        return false, 'it waited inside the scheduler (anything that waits goes in ctx:call)'
    end
    return ok, a, b
end

local function wake()
    if passing or wakeAsked or not Ports.wake then return end
    wakeAsked = true
    local ok, err = pcall(Ports.wake)
    if not ok then wakeAsked = false; Ports.log('wake failed: ' .. tostring(err)) end
end

-- ============================================
-- Trace (what the editor replays as wire pulses)
-- ============================================

local function trace(run, node, pin, kind, from, fromPin, text)
    local t = run.trace
    t.n = t.n + 1
    -- `n`: its place in the run's steps, which a test rewinds to (R.rewind).
    local e = { t = Ports.now(), n = t.n, node = node, pin = pin, kind = kind, from = from, fromPin = fromPin, text = text }
    t[((t.n - 1) % L.trace) + 1] = e
    -- A watcher (Test mode's strip and window, live pulses): told of each step, and what a card said ('log'), never able
    -- to break the run.
    if run.onTrace then
        local ok, err = pcall(run.onTrace, e, run)
        if not ok then
            run.onTrace = nil
            Ports.log(('run %d: its trace watcher failed and was dropped: %s'):format(run.id, tostring(err)))
        end
    end
end

-- ============================================
-- Waits and activations
-- ============================================

local function kill(w)
    if w.dead then return end
    w.dead = true
    if w.counts then w.run.live = w.run.live - 1 end
    if w.event then dirtyEvents = true end
    if w.kind == 'hold' then holds[w.id] = nil end
end

--- End an activation: its waits die, and its end hooks hear (pin, why) once each.
local function endToken(run, tok, pin, why)
    if tok.dead then return end
    tok.dead = true
    for _, w in ipairs(tok.waits) do kill(w) end
    if run.active[tok.node] == tok then run.active[tok.node] = nil end
    if tok.onEnd then
        for _, fn in ipairs(tok.onEnd) do
            Ports.threadNow(function()
                local ok, err = pcall(fn, pin, why)
                if not ok then Ports.log(('run %d card %s: its end hook failed: %s'):format(run.id, tok.node, tostring(err))) end
            end)
        end
    end
end

-- ============================================
-- Ending a run
-- ============================================

--- AFTER THE END: a run that fails (succeeds) with an Activate After Failure (Success) card (def.after) plays that
--- card's chain first. Everything else of it stops (its waits end, its listeners go); the chain has L.afterSec; then
--- the run ends as it was going to, its outcome and reason (finish: run.after). Answers whether one began.
local function startAfter(run, outcome, reason, nodeId)
    local starts = {}
    for id, n in pairs(run.graph.nodes) do
        if n.def and n.def.after == outcome then starts[#starts + 1] = id end
    end
    if #starts == 0 then return false end
    table.sort(starts)
    run.after, run.final = outcome, { outcome = outcome, reason = reason, nodeId = nodeId }
    local toks = {}
    for _, tok in pairs(run.active) do toks[#toks + 1] = tok end
    for _, tok in ipairs(toks) do endToken(run, tok, nil, 'run ended') end
    run.active = {}
    for _, w in ipairs(run.listeners) do kill(w) end
    run.listeners = {}
    dirtyEvents = true
    run.q, run.live = newDeque(), 0
    run.deadlineAt = Ports.now() + L.afterSec * 1000
    for _, id in ipairs(starts) do pushBack(run.q, { node = id, depth = 0, data = { source = run.starter } }) end
    Ports.log(('run %d (%s) %s%s: its After cards play first'):format(run.id, tostring(run.scenarioId), outcome,
        reason and (': ' .. tostring(reason)) or ''))
    wake()
    return true
end

local function finish(run, outcome, reason, nodeId)
    if run.status ~= 'running' then return false end
    -- Still in its lead-in (before Scenario Run Started By Player): nothing counts, so it ends as called off, telling
    -- nobody.
    if run.pre and outcome ~= 'faulted' and outcome ~= 'aborted' then
        reason = 'before Scenario Started By Player' .. (reason and (': ' .. tostring(reason)) or '')
        outcome = 'aborted'
    end
    if run.pre and outcome == 'aborted' then run.quiet = true end
    if run.after then
        -- Its After chain is over (or out of time): the run ends as it was going to.
        outcome, reason, nodeId = run.final.outcome, run.final.reason, run.final.nodeId
    elseif (outcome == 'failed' or outcome == 'succeeded') and startAfter(run, outcome, reason, nodeId) then
        return true
    end
    run.status = outcome
    run.reason = reason
    run.faultNode = nodeId
    run.endedAt = Ports.now()
    local toks = {}
    for _, tok in pairs(run.active) do toks[#toks + 1] = tok end
    for _, tok in ipairs(toks) do endToken(run, tok, nil, 'run ended') end
    run.active = {}
    for _, w in ipairs(run.listeners) do kill(w) end
    run.q = newDeque()
    runs[run.id] = nil
    dirtyEvents = true
    Ports.log(('run %d (%s) %s%s'):format(run.id, tostring(run.scenarioId), outcome,
        reason and (': ' .. tostring(reason)) or ''))
    if Ports.onEnd then
        Ports.threadNow(function()
            local ok, err = pcall(Ports.onEnd, run, outcome, reason)
            if not ok then Ports.log(('run %d: onEnd failed: %s'):format(run.id, tostring(err))) end
        end)
    end
    return true
end

local function fault(run, nodeId, msg)
    if run.status ~= 'running' then return false end
    Ports.log(('run %d faulted at card %s: %s'):format(run.id, tostring(nodeId), tostring(msg)))
    return finish(run, 'faulted', tostring(msg), nodeId)
end

-- ============================================
-- Following wires
-- ============================================

--- Queue the cards an output pin leads to, carrying `data` (the trigger) along.
--- front = continue now (depth-first); back = resumed from a wait.
local function follow(run, nodeId, pin, depth, front, data)
    -- Every outcome a card gives is counted, wired on or not (an NPC's Wait for a card watches these:
    -- server/director/nodes_tasks.lua, R.firedCount).
    local fired = run.fired
    if not fired then fired = {}; run.fired = fired end
    local key = tostring(nodeId) .. ':' .. tostring(pin)
    fired[key] = (fired[key] or 0) + 1
    local byPin = run.graph.out[nodeId]
    local targets = byPin and byPin[pin]
    if not targets then return end
    if front then
        for i = #targets, 1, -1 do
            pushFront(run.q, { node = targets[i].node, pin = targets[i].pin, depth = depth, data = data, from = nodeId, fromPin = pin })
        end
    else
        for i = 1, #targets do
            pushBack(run.q, { node = targets[i].node, pin = targets[i].pin, depth = depth, data = data, from = nodeId, fromPin = pin })
        end
        wake()
    end
end

--- Why a wait went on, as its step says it (a test's window shows it beside the outcome).
local WHY = {
    timer = function(w) return ('its time came (%d s)'):format(math.floor(((w.at or 0) - (w.made or 0)) / 1000 + 0.5)) end,
    event = function(w) return 'it heard ' .. tostring(w.event) end,
    poll  = function() return 'what it checks for came true' end,
    call  = function() return 'its work was done' end,
    hold  = function() return 'it was answered' end,
}

--- A wait fired with `pin` (and `data`, the trigger for what follows).
--- Does the card this wait is of still wait on something else (a wait of its own besides this one)?
local function liveBeside(w)
    for _, o in ipairs(w.token and w.token.waits or {}) do
        if o ~= w and not o.dead then return true end
    end
    return false
end

--- A loop through a call thread and an event can lap once a tick for ever without a long chain or a full queue: count
--- how often the run is woken from outside its pass (a wait answered, an outcome given while its card waits on).
local function tooOften(run)
    local t = Ports.now()
    if t - run.rateAt >= 1000 then run.rateAt, run.rate = t, 0 end
    run.rate = run.rate + 1
    return run.rate > L.resumesPerSec
end
local RUNAWAY = ('runaway: woken more than %d times in a second'):format(L.resumesPerSec)

local function resolve(w, pin, data)
    if w.dead then return false end
    local run = w.run
    if run.status ~= 'running' then kill(w) return false end
    local node = run.graph.nodes[w.node]
    if not node or not node.def or not node.def._outputs[pin] then
        return fault(run, w.node, ('a wait answered "%s", which this card does not have'):format(tostring(pin)))
    end
    if tooOften(run) then
        kill(w)
        return fault(run, w.node, RUNAWAY)
    end
    -- How deep the chain is now. Inside a card (an event the run fired itself) or soon after the
    -- wait was made, the count carries on: a loop through a 0 s wait is still a loop.
    local d
    if run.curDepth then
        d = run.curDepth + 1
    elseif Ports.now() - (w.made or -math.huge) < L.quickMs then
        d = (w.depth or 0) + 1
    else
        d = 0
    end
    if w.persistent then
        if w.once then kill(w) end
    else
        endToken(run, w.token, pin, 'answered')
    end
    if data == nil and w.token then data = w.token.trigger end
    trace(run, w.node, pin, 'resume', nil, nil, WHY[w.kind] and WHY[w.kind](w) or nil)
    follow(run, w.node, pin, d, false, data)
    return true
end

-- ============================================
-- What a card's code is handed (ctx)
-- ============================================

local CTX = {}
CTX.__index = CTX

local function newWait(ctx, kind)
    local tok = ctx.token
    if not tok then error('only a waiting card can wait (mark the card type latent)', 3) end
    if tok.dead or ctx.run.status ~= 'running' then return nil end   -- it already went on
    nextWaitId = nextWaitId + 1
    local w = { id = nextWaitId, run = ctx.run, node = ctx.node.id, kind = kind, token = tok,
                depth = ctx.depth, made = Ports.now(), counts = true }
    tok.waits[#tok.waits + 1] = w
    ctx.run.live = ctx.run.live + 1
    return w
end

--- A value read through a variable is checked against its field like a saved one would be (its kind's rule:
--- DirectorFields.fromVar).
local function fieldValue(self, f, v)
    return DirectorFields.fromVar(f, v, { world = self.run.graph.world })
end

--- A prop's value: the card's own, a run variable it names ({ var = 'x' }, checked against the
--- field), or the type's default. Tables are copies: the compiled graph is shared by every run.
function CTX:prop(key)
    -- A price a Haggle agreed for this card (its Haggling for): it stands in for the card's own (def.haggle.key).
    local hg = self.node.def.haggle
    if hg and key == hg.key then
        local agreed = self.run.haggled and self.run.haggled[self.node.id]
        if agreed ~= nil then return agreed end
    end
    local f = self.node.def._fields[key]
    local v = self.node.props[key]
    if type(v) == 'table' and v.var ~= nil then
        local got = fieldValue(self, f, self.run.vars[v.var])
        if got == nil and self.run.vars[v.var] ~= nil then
            self:log('%s: variable %s holds a value this field cannot use', key, tostring(v.var))
        end
        return got
    end
    if v == nil and f then v = f.default end
    -- An empty lore field is the scenario's own lore character (server/director/lore.lua).
    if f and f.kind == 'lore' and (v == nil or v == '') and DirectorLore then v = DirectorLore.defaultOf(self.run.graph) end
    return deepCopy(v)
end

function CTX:var(name) return self.run.vars[name] end
function CTX:setVar(name, value) R.setVar(self.run, name, value) end

--- THE ONE WAY A RUN'S VARIABLE IS WRITTEN (cards, SetScenarioRunVar, a late answer): one place for
--- anything that must hear of a change later.
function R.setVar(run, name, value)
    run.vars[name] = value
end

--- This card's own memory in this run (First Time Only, Wait for All).
--- The card's own memory for the run. Made at the step it was first asked for (run.stateAt): a test rewound to before
--- that step forgets it, unless the card says how its memory goes back (its def's `rewind(state, seq)`: R.rewind).
function CTX:state()
    local s = self.run.state[self.node.id]
    if not s then
        s = {}
        self.run.state[self.node.id] = s
        self.run.stateAt = self.run.stateAt or {}
        self.run.stateAt[self.node.id] = self.seq or 0
    end
    return s
end

--- Which of this card's inputs have wires into them.
function CTX:wired(pin)
    local w = self.run.graph.wiredIn[self.node.id]
    return w ~= nil and (w[pin] or 0) > 0
end

--- A COPY of a placed thing's definition (never write into the shared graph). A run started with
--- its own places (StartScenarioRun's opts.places: today's territory) has those coords instead.
function CTX:place(worldId) return R.place(self.run, worldId) end

--- The same, for a run (no card): what its props will be, before a card shows them (nodes_props.lua).
function R.place(run, worldId)
    local w = deepCopy(run.graph.world[worldId])
    local at = run.places and run.places[worldId]
    if w and at then
        w.def = type(w.def) == 'table' and w.def or {}
        w.def.coords = { x = at.x, y = at.y, z = at.z, heading = at.heading }
        -- Inside an MLO or not is the PLACE's (the World tab's answer was for its own spot): a safe
        -- placed in a bank and moved to a street must not wait for an interior that is not there.
        w.def.interior = at.interior == true or nil
        w.def.gateAt = nil
    end
    return w
end

--- What the run made for a placed thing (an npcId, a vehicleId, a ground id), and setting it.
function CTX:handle(worldId) return self.run.world[worldId] end
function CTX:remember(worldId, value)
    self.run.world[worldId] = value
    -- The step whose card made it (a test rewound to before that takes it away: R.rewind).
    local made = self.run.madeAt
    if not made then made = {}; self.run.madeAt = made end
    made[worldId] = type(value) == 'table' and self.seq or nil
    -- Other resources hear it (whip_core:run:thingMade, after the pass), with what each keeps on the thing.
    if type(value) == 'table' then Director.thingMade(self.run, worldId, value) end
end

--- THE RUN'S LEDGER: what this card put out in the world that is the run's to give back, and how (release(why), why
--- 'ended' | 'stopping' (whip_core stopping: what is saved as it lies, a ground pile, stays for the boot's sweep) |
--- 'rewound'). The run's end gives back every entry, newest first; a test rewound to before the step that made one
--- gives that one back (R.release). What a run's TAG holds (its NPCs, props, blips, points) goes with the tag: the
--- ledger is for what the tag does not reach. Answers the entry: entry.done() when the card gave it back itself.
---@param release fun(why: string)
---@param what string|nil  what it is, for the console when giving it back fails
function CTX:own(release, what)
    local run = self.run
    run.owned = run.owned or {}
    local e = { release = release, seq = self.seq or 0, node = self.node.id, what = what }
    e.done = function() e.released = true end
    run.owned[#run.owned + 1] = e
    return e
end

--- Give back what a run's ledger holds (CTX:own), newest first: every entry, or (afterSeq) only those made after that
--- step (a test rewound). Never stops for one that fails.
function R.release(run, why, afterSeq)
    local list, keep = run.owned or {}, {}
    for i = #list, 1, -1 do
        local e = list[i]
        if not e.released and (afterSeq == nil or e.seq > afterSeq) then
            e.released = true
            local ok, err = pcall(e.release, why)
            if not ok then Ports.log(('run %d: giving back %s failed: %s'):format(run.id, tostring(e.what or 'something'), tostring(err))) end
        end
    end
    for _, e in ipairs(list) do if not e.released then keep[#keep + 1] = e end end
    run.owned = keep
end

--- The run's tag: every world card hands it to the module it calls, so ReleaseTag finds it.
function CTX:tag()
    if not self.run.tag then error('this run has no tag', 2) end
    return self.run.tag
end

--- The run's players, in a fixed order, and whether one is in it.
function CTX:players()
    local out = {}
    for s in pairs(self.run.players) do out[#out + 1] = s end
    table.sort(out)
    return out
end
function CTX:isPlayer(src) return self.run.players[src] == true end

--- Is this card's work still wanted: its run going, and this activation not ended (answered, restarted, a test rewound,
--- the run's After cards playing)? A wait inside ctx:call that loops asks it each time round, and once more before it
--- acts: the run alone can still be 'running' while its After cards play.
function CTX:alive()
    return self.run.status == 'running' and not (self.token and self.token.dead)
end

--- Continue from `pin` in `ms` (at least 50 ms, at most a week).
function CTX:after(ms, pin)
    if not self.node.def._outputs[pin] then error(('"%s" is not one of this card\'s pins'):format(tostring(pin)), 2) end
    local w = newWait(self, 'timer')
    if not w then return nil end
    local n = tonumber(ms) or 0
    if n ~= n then n = 0 end
    n = math.min(math.max(n, L.minWaitMs), L.maxWaitMs)
    w.at = Ports.now() + math.ceil(n)
    w.pin = pin
    heapPush(w)
    return w.id
end

--- Continue when fn() answers a pin (and optionally data), asking it every `ms` (250 ms to a minute,
--- default a second): for what no event tells, such as a car reaching a spot. fn must not wait (it
--- runs in the scheduler's pass, guarded as event filters are); an error faults the run.
function CTX:poll(ms, fn)
    local w = newWait(self, 'poll')
    if not w then return nil end
    local n = tonumber(ms) or 1000
    if n ~= n then n = 1000 end
    w.every = math.min(math.max(n, 250), 60000)
    w.poll = fn
    w.at = Ports.now() + math.ceil(w.every)
    heapPush(w)
    return w.id
end

--- Continue when `name` is emitted and filter(payload) answers a pin (and optionally data);
--- nil = not this one. The name must be one the Director listens for (R.bridge).
function CTX:on(name, filter)
    if not bridged[name] then error(('nothing sends "%s" to the Director'):format(tostring(name)), 2) end
    local w = newWait(self, 'event')
    if not w then return nil end
    w.event, w.filter = name, filter
    local list = eventWaits[name]
    if not list then list = {}; eventWaits[name] = list end
    list[#list + 1] = w
    return w.id
end

--- Run fn() in its own thread (it may yield: the database, a player, Whip.call) and continue from
--- the pin it answers; its second answer becomes the trigger for what follows. An error faults the
--- run. If the activation ended first (its timeout won, it was restarted, the run ended), fn is not
--- started at all, or, if it was already running, its answer goes to opts.late(...) so whatever it
--- made can be put away. While it runs the card is busy: a pulse into it is dropped. fn answering no pin
--- while the card waits on something else it set (a ctx:poll, after a ctx:emit) is its part done: the card
--- goes on waiting on that. With nothing else, no pin is a fault, as a pin the card has not got is.
function CTX:call(fn, opts)
    local w = newWait(self, 'call')
    if not w then return nil end
    Ports.thread(function()
        if w.dead then return end
        w.started = true
        local r = table.pack(pcall(fn))
        if w.dead then
            if r[1] and opts and opts.late ~= nil then
                local ok, err = pcall(opts.late, table.unpack(r, 2, r.n))
                if not ok then Ports.log(('card %s: its late handler failed: %s'):format(w.node, tostring(err))) end
            end
            return
        end
        if not r[1] then
            fault(w.run, w.node, 'it failed: ' .. tostring(r[2]))
            return
        end
        if r[2] == nil and liveBeside(w) then kill(w) return end
        resolve(w, r[2], r[3])
    end)
    return w.id
end

--- Give outcome `pin` NOW and go on waiting: what it leads to plays, and the card answers again when one of its waits
--- does (Start Tasks: Started now, Finished later). From its run (as answering the pin with a wait set would), a call's
--- thread or a poll. `data` the trigger for what follows (default the card's own). False when the card is over.
---@return boolean given
function CTX:emit(pin, data)
    if not self.node.def._outputs[pin] then error(('"%s" is not one of this card\'s pins'):format(tostring(pin)), 2) end
    local run = self.run
    if not self:alive() then return false end
    if data == nil then data = self.token and self.token.trigger or self.trigger end
    -- Inside the run's pass (its own run, or a card it led to): on at once, depth-first, as an answered pin is.
    -- From outside (a thread, a poll): a wake, counted as an answered wait is.
    local inside = run.curDepth ~= nil
    if not inside and tooOften(run) then fault(run, self.node.id, RUNAWAY) return false end
    trace(run, self.node.id, pin, 'out')
    if inside then follow(run, self.node.id, pin, run.curDepth + 1, true, data)
    else follow(run, self.node.id, pin, 0, false, data) end
    return true
end

--- Continue when R.answer(id, pin, data) names a pin: for a card whose answer comes from OUTSIDE the
--- runtime (another resource's card: a thread it runs, or AnswerDirectorCard from an officer's accept
--- button). Answers the hold's id. While it is open the card is busy: a pulse into it is dropped, never
--- a second call of the other resource's code.
function CTX:hold()
    local w = newWait(self, 'hold')
    if not w then return nil end
    holds[w.id] = w
    return w.id
end

--- Answer a hold (CTX:hold): its card goes on from `pin`, `data` the trigger for what follows. False
--- when it is gone (the card already went on: its time ran out, it was pulsed again, its run ended),
--- or the pin is not one of the card's (the run faults, as for any wait).
---@return boolean answered
function R.answer(id, pin, data)
    local w = holds[id]
    if not w or w.dead then return false end
    return resolve(w, pin, data) == true
end

--- Is the hold still waiting for its answer?
function R.holding(id)
    local w = holds[id]
    return w ~= nil and not w.dead
end

--- Fault a run from outside a card's code (another resource's card: its Didn't Work with nothing wired).
---@return boolean faulted
function R.fault(run, nodeId, msg)
    return fault(run, nodeId, msg)
end

--- Does a wire leave this card's pin?
function R.wired(run, nodeId, pin)
    local byPin = run.graph.out[nodeId]
    local targets = byPin and byPin[pin]
    return targets ~= nil and #targets > 0
end

--- Be told once when this activation ends: fn(pin, why) with why 'answered' (pin = the winner),
--- 'restarted' or 'run ended' (pin = nil). For closing what the card opened (a conversation, a bar).
function CTX:onEnd(fn)
    if not self.token then error('only a waiting card has an end', 2) end
    if self.token.dead then
        Ports.threadNow(function() pcall(fn, nil, 'already ended') end)
        return
    end
    self.token.onEnd = self.token.onEnd or {}
    self.token.onEnd[#self.token.onEnd + 1] = fn
end

--- End the run: 'success', 'failure', or 'calloff' (no result: the player said no). A called-off run
--- ends as 'aborted', counted as neither, and `quiet` (nobody is told it was called off), with `calledOff` (no
--- cooldown: server/director/main.lua's runEnded).
function CTX:finish(outcome, reason)
    if outcome == 'calloff' then
        self.run.quiet, self.run.calledOff = true, true
        finish(self.run, 'aborted', reason)
        return
    end
    finish(self.run, outcome == 'success' and 'succeeded' or 'failed', reason)
end

--- A FAIL CONDITION's rule broken (its watch, or another resource's fail event): the run fails for everyone with
--- `reason` (the card's own Why when nil), or (`onlyThem`, about one player) only that player is out of it.
---@return boolean acted
function CTX:broken(src, onlyThem, reason)
    return R.broken(self.run, self.node.id, src, reason or self:prop('reason'), onlyThem)
end

--- The same for a run: once a run, and once a player, for each card. Its step says so (a test shows the card that
--- broke it); Ports.broken hears it before it acts (the run's history, the player told).
---@return boolean acted
function R.broken(run, nodeId, src, reason, onlyThem)
    if run.status ~= 'running' then return false end
    reason = (type(reason) == 'string' and reason ~= '') and reason or 'a rule of the job was broken'
    local them = onlyThem == true and src ~= nil
    run.brokenBy = run.brokenBy or {}
    local seen = run.brokenBy[nodeId]
    if not seen then seen = {}; run.brokenBy[nodeId] = seen end
    if them then
        if seen[src] or not run.players[src] then return false end
        seen[src] = true
    else
        if seen.run then return false end
        seen.run = true
    end
    trace(run, nodeId, nil, 'broken', nil, nil, DirectorKit.cut(reason, 200))
    if Ports.broken then
        local ok, err = pcall(Ports.broken, run, nodeId, src, reason, them)
        if not ok then Ports.log(('run %d card %s: telling of its broken rule failed: %s'):format(run.id, tostring(nodeId), tostring(err))) end
    end
    if them then
        -- (Taking a player out tells every page and gives back what they were handed: in a thread of its own, never
        -- inside the pass or a card's guarded code.)
        Ports.thread(function()
            if run.status ~= 'running' then return end
            if Ports.takeOut then Ports.takeOut(run, src, reason) else R.removePlayer(run, src, reason) end
        end)
    else
        finish(run, 'failed', reason)
    end
    return true
end

function CTX:log(fmt, ...)
    local text = tostring(fmt):format(...)
    Ports.log(('run %d card %s: %s'):format(self.run.id, self.node.id, text))
    -- (In the trace too: a test's Check shows it beside the card's step, app.js readTrace.)
    trace(self.run, self.node.id, nil, 'log', nil, nil, DirectorKit.cut(text, 200))
end

-- ============================================
-- Running one card
-- ============================================

--- Runs one pulse. Answers the card type (the pass reads .heavy), or nil.
local function exec(run, p)
    local node = run.graph.nodes[p.node]
    if not node then fault(run, p.node, 'a wire leads to a card that does not exist') return nil end
    local def = node.def
    if not def then fault(run, p.node, 'unknown card type ' .. tostring(node.type)) return nil end
    if p.depth > L.chain then
        fault(run, p.node, ('runaway: %d cards in a row without a pause'):format(L.chain))
        return def
    end
    run.burst = run.burst + 1
    if run.burst > L.burst then
        fault(run, p.node, ('runaway: %d cards without the run ever pausing'):format(L.burst))
        return def
    end
    run.steps = run.steps + 1

    -- ONLY ONCE (nodes.lua): set to do its work the first time only, and reached again in this run, the card is
    -- skipped: the run goes straight on through its onceOut, as a pass-through would. (Its switch may name a
    -- variable, as any field may.)
    local once = def.once and node.props.onlyOnce
    if type(once) == 'table' and once.var ~= nil then once = run.vars[once.var] end
    if once == true then
        if run.played[node.id] then
            trace(run, node.id, p.pin, 'skipped', p.from, p.fromPin)
            trace(run, node.id, def.onceOut, 'out')
            follow(run, node.id, def.onceOut, p.depth + 1, true, p.data)
            return def
        end
        run.played[node.id] = run.trace.n + 1   -- (the step it is about to be: R.rewind forgets one played after)
    end

    local ctx = setmetatable({ run = run, node = node, pin = p.pin, depth = p.depth, trigger = p.data }, CTX)
    if def.latent then
        local cur = run.active[node.id]
        if cur then
            if def.retrigger == 'ignore' then trace(run, node.id, p.pin, 'ignored', p.from, p.fromPin) return def end
            -- A call already under way cannot be taken back: never run its work twice at once. Nor a
            -- hold (another resource's card at work, or waiting for its answer).
            for _, w in ipairs(cur.waits) do
                if ((w.kind == 'call' and w.started) or w.kind == 'hold') and not w.dead then
                    trace(run, node.id, p.pin, 'busy', p.from, p.fromPin)
                    return def
                end
            end
            endToken(run, cur, nil, 'restarted')
        end
        ctx.token = { node = node.id, waits = {}, trigger = p.data }
        run.active[node.id] = ctx.token
    end

    trace(run, node.id, p.pin, 'enter', p.from, p.fromPin)
    ctx.seq = run.trace.n
    run.curDepth = p.depth
    local ok, res, data = runGuarded(def.run, ctx)
    run.curDepth = nil
    if not ok then fault(run, node.id, res) return def end
    if run.status ~= 'running' then return def end
    -- Its own Took Too Long (def.giveUp, seconds: nodes.lua): armed whenever it is left waiting, said once by the card's
    -- definition, not by each run function.
    if res == nil and def.giveUp and ctx.token and not ctx.token.dead and #ctx.token.waits > 0 then
        ctx:after(def.giveUp * 1000, 'timeout')
    end
    if ctx.token and not ctx.token.dead and #ctx.token.waits == 0 then
        endToken(run, ctx.token, nil, 'no wait')
    end
    if res == nil then return def end
    if type(res) == 'string' then res = { res } end
    if type(res) ~= 'table' then fault(run, node.id, 'answered something that is not a pin') return def end
    for i = 1, #res do
        if not def._outputs[res[i]] then
            fault(run, node.id, ('answered "%s", which this card does not have'):format(tostring(res[i])))
            return def
        end
    end
    if data == nil then data = p.data end
    for i = 1, #res do trace(run, node.id, res[i], 'out') end
    for i = #res, 1, -1 do follow(run, node.id, res[i], p.depth + 1, true, data) end
    return def
end

-- ============================================
-- Public
-- ============================================

--- Let event `name` reach the Director (the start-up wiring calls this for every whip event it
--- bridges). Cards may only listen for bridged names.
function R.bridge(name) bridged[name] = true end

--- How many times a card of the run has given an outcome (follow counts them).
function R.firedCount(run, nodeId, pin)
    local fired = type(run) == 'table' and run.fired
    return fired and fired[tostring(nodeId) .. ':' .. tostring(pin)] or 0
end

--- Run ids continue from the database's (the Director's loader calls this at boot).
function R.seedIds(n)
    n = math.tointeger(tonumber(n) or 0) or 0
    if n > nextRunId then nextRunId = n end
end

--- Has the scenario a Scenario Run Started By Player card (a lead-in before its job)? Asked once a graph.
local function hasBegin(graph)
    if graph.hasBegin == nil then
        graph.hasBegin = false
        for _, n in pairs(graph.nodes or {}) do
            if n.type == 'scenario.begin' then graph.hasBegin = true break end
        end
    end
    return graph.hasBegin
end
R.hasBegin = hasBegin

--- Start a run of a compiled graph.
---@param graph table   DirectorGraph.compile's result
---@param opts table    { scenarioId, rev, tag?, test, players = { src, ... }, starter, trigger, vars,
---                       places? = { [worldId] = coords } (this run's own: CTX:place),
---                       onTrace? = fn(step, run): told of every step from the first }
---@return table|false run
---@return string|nil why
function R.start(graph, opts)
    opts = opts or {}
    local test = opts.test == true
    local count, same = 0, 0
    for _, r in pairs(runs) do
        -- (A switched-on scenario's run that nobody has joined yet is not one of L.runs: there is one per scenario
        -- switched on, waiting for ever, and they filled the cap for real jobs.)
        if not r.open then count = count + 1 end
        if opts.scenarioId ~= nil and r.scenarioId == opts.scenarioId and r.test == test then
            if test and r.starter == opts.starter then return false, 'you are already testing this scenario' end
            -- (A lead-in holds none of its Runs at once: Scenario Run Started By Player asks, Director.beginRun.)
            if not r.pre then same = same + 1 end
        end
    end
    if count >= L.runs then return false, 'too many scenarios are running' end
    local settings = graph.settings or {}
    -- (A scenario with variants says its own: Director.maxRuns, one run per variant.)
    local maxSame = tonumber(opts.maxSame) or tonumber(settings.maxConcurrentRuns) or 1
    if not test and same >= maxSame then return false, 'this scenario is already running' end
    for name in pairs(graph.events) do
        if not bridged[name] then return false, ('this scenario listens for "%s", which nothing sends'):format(name) end
    end

    nextRunId = nextRunId + 1
    local always = type(settings.start) == 'table' and settings.start.mode == 'always'
    -- OPEN: started as its scenario was switched on, with nobody in it yet (main.lua Director.openRun). A lead-in until a
    -- player joins (Director.claim: open goes, `opened` stays), with no time limit and never ending for having nothing
    -- left to wait for: what it put out stays out for whoever comes.
    local open = opts.open == true and not test
    local maxSec = tonumber(settings.maxRunSec) or L.maxRunSec
    local run = {
        id = nextRunId, scenarioId = opts.scenarioId, rev = opts.rev, test = test, always = always,
        open = open or nil, opened = open or nil, maxSec = maxSec,
        variant = opts.variant,   -- the variant it plays, when its scenario has more than one ('v2'...)
        graph = graph, players = {}, starter = opts.starter, vars = {}, state = {}, world = {}, active = {},
        listeners = {}, live = 0, burst = 0, rate = 0, rateAt = Ports.now(), q = newDeque(), status = 'running',
        startedAt = Ports.now(), steps = 0, trace = { n = 0 },
        played = {},   -- [card id] = its step: an Only Once card that has done its work (exec)
        -- A watcher from the start (live pulses): Scenario Enabled fires inside this call, before the
        -- caller could set one on the run it gets back.
        onTrace = type(opts.onTrace) == 'function' and opts.onTrace or nil,
    }
    run.tag = opts.tag or ('run:' .. run.id)
    run.maxSame = maxSame
    if not always and not open and maxSec > 0 then run.deadlineAt = run.startedAt + maxSec * 1000 end
    if open then
        run.pre = true   -- (its times start as a player joins: R.claimed, R.begun)
    elseif not always and hasBegin(graph) then
        run.pre = true
        run.preDeadlineAt = run.startedAt + L.preSec * 1000
    end
    for _, s in ipairs(opts.players or {}) do run.players[s] = true end
    if opts.starter ~= nil then run.players[opts.starter] = true end
    for name, v in pairs(graph.vars) do run.vars[name] = v.default end
    for name, v in pairs(opts.vars or {}) do run.vars[name] = v end
    if type(opts.places) == 'table' then run.places = deepCopy(opts.places) end
    runs[run.id] = run
    order[#order + 1] = run.id

    -- Event cards listen for the whole run.
    local names = {}
    for name in pairs(graph.events) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        for _, nodeId in ipairs(graph.events[name]) do
            local node = graph.nodes[nodeId]
            local ev = node.def.event
            local ctx = setmetatable({ run = run, node = node, pin = nil, depth = 0 }, CTX)
            nextWaitId = nextWaitId + 1
            -- A Fail Condition (def.condition: nodes_conditions.lua) watches the whole run and is never what keeps it
            -- going: a run with nothing else left still ends ("nothing left to wait for").
            local watches = node.def.condition == true
            local w = { id = nextWaitId, run = run, node = nodeId, kind = 'event', event = name, persistent = true,
                        once = ev.once == true, counts = not watches, depth = 0, made = Ports.now() }
            w.filter = function(payload)
                if ev.filter then return ev.filter(ctx, payload) end
                return node.def.outputs[1], payload
            end
            if not watches then run.live = run.live + 1 end
            local list = eventWaits[name]
            if not list then list = {}; eventWaits[name] = list end
            list[#list + 1] = w
            run.listeners[#run.listeners + 1] = w
        end
    end
    -- A Fail Condition's watch (def.watch): a look at the run every def.every ms, for the whole run. It never keeps the
    -- run going, and it is a listener: the run's end (or its After cards) stops it.
    for _, nodeId in ipairs(graph.watches or {}) do
        local node = graph.nodes[nodeId]
        local ctx = setmetatable({ run = run, node = node, pin = nil, depth = 0 }, CTX)
        nextWaitId = nextWaitId + 1
        local w = { id = nextWaitId, run = run, node = nodeId, kind = 'watch', persistent = true, counts = false, depth = 0,
                    made = Ports.now(), every = node.def.every, at = Ports.now() + node.def.every }
        w.watch = function() return node.def.watch(ctx) end
        heapPush(w)
        run.listeners[#run.listeners + 1] = w
    end

    Ports.log(('run %d (%s rev %s) started%s'):format(run.id, tostring(run.scenarioId), tostring(run.rev),
        test and ' [TEST]' or ''))
    R.emit('scenario.started', { runId = run.id, source = opts.starter, starter = opts.starter, from = opts.trigger }, run)
    wake()
    return run
end

--- Tell waiting runs that something happened. With `onlyRun`, only that run hears it.
---@param name string
---@param payload table|nil
---@param onlyRun table|nil
---@return number resumed
function R.emit(name, payload, onlyRun)
    local list = eventWaits[name]
    if not list then return 0 end
    local resumed = 0
    local n = #list   -- waits added while dispatching wait for the next emit
    for i = 1, n do
        local w = list[i]
        if not w.dead and (onlyRun == nil or w.run == onlyRun) and w.run.status == 'running' then
            local ok, pin, data = runGuarded(w.filter, payload)
            if not ok then
                fault(w.run, w.node, 'its event check failed: ' .. tostring(pin))
            elseif pin ~= nil then
                if data == nil then data = payload end
                if resolve(w, pin, data) then resumed = resumed + 1 end
            end
        end
    end
    if dirtyEvents then compactEvents() end
    return resumed
end

--- Add a player to a running run (a Join card, an admin).
function R.addPlayer(run, src)
    if run and run.status == 'running' and src ~= nil then run.players[src] = true end
end

--- An open run's first player joined (main.lua Director.claim): it is open no more. With a Scenario Run Started By
--- Player card, its lead-in has L.preSec from now to get there.
function R.claimed(run)
    run.open = nil
    if run.pre and hasBegin(run.graph) then run.preDeadlineAt = Ports.now() + L.preSec * 1000 end
end

--- A run's job began (main.lua Director.beginRun): one that opened with nobody in it has its time limit from now.
function R.begun(run)
    if run.opened and not run.deadlineAt and (run.maxSec or 0) > 0 then
        run.deadlineAt = Ports.now() + run.maxSec * 1000
    end
end

--- A pulse into one of a run's cards from outside its pass, as a wire would bring one: `data` its trigger. For a card
--- that waited for anyone in an open run, played again for the player who came (main.lua Director.waitForAnyone).
---@return boolean sent
function R.pulse(run, nodeId, pin, data)
    if not run or run.status ~= 'running' or not run.graph.nodes[nodeId] then return false end
    pushBack(run.q, { node = nodeId, pin = pin or 'in', depth = 0, data = data })
    wake()
    return true
end

--- One player out of ONE run: logging out, disconnecting, another resource taking them out
--- (RemovePlayerFromScenarioRun) all come here, one run at a time (main.lua leaveRun). The run hears
--- 'player.left'; one left with nobody ends, unless it is an 'always' run.
---@return boolean removed
function R.removePlayer(run, src, why)
    if not run or run.status ~= 'running' or not run.players[src] then return false end
    run.players[src] = nil
    R.emit('player.left', { source = src, why = why }, run)
    if run.status == 'running' and not run.always and next(run.players) == nil then
        finish(run, 'aborted', 'the last player left')
    end
    return true
end

--- End a run from outside the way a card would: 'succeeded' (Succeed), 'failed' (Fail) or
--- 'calledOff' (Call Off: no result, nobody told). EndScenarioRun.
---@return boolean ended
function R.finishRun(runId, outcome, reason)
    local run = runs[runId]
    if not run then return false end
    if outcome == 'calledOff' then
        run.quiet, run.calledOff = true, true
        return finish(run, 'aborted', reason)
    end
    if outcome ~= 'succeeded' and outcome ~= 'failed' then return false end
    return finish(run, outcome, reason)
end

--- End a run from outside (an admin, a reset, whip_core stopping).
---@return boolean ended
function R.abort(runId, reason)
    local run = runs[runId]
    if not run then return false end
    return finish(run, 'aborted', reason or 'aborted')
end

--- Abort every run (whip_core stopping). Each run's onEnd has started before this returns.
function R.abortAll(reason)
    local ids = {}
    for id in pairs(runs) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do R.abort(id, reason) end
end

---@return table|nil run
function R.get(runId) return runs[runId] end

---@return table list   running runs, by id
function R.list()
    local out = {}
    for _, id in ipairs(order) do if runs[id] then out[#out + 1] = runs[id] end end
    return out
end

-- ============================================
-- A test's tester at the wheel (hub.lua: the test window)
-- ============================================

--- The card waiting at `nodeId` goes on from `pin` now, as if that was its answer (its end hooks hear 'answered', so
--- what it opened closes). False when it is not waiting, the run is over, or it has no such pin.
---@return boolean taken
function R.take(run, nodeId, pin)
    if not run or run.status ~= 'running' then return false end
    local tok = run.active[nodeId]
    local node = run.graph.nodes[nodeId]
    if not tok or tok.dead or not node or not node.def or not node.def._outputs[pin] then return false end
    endToken(run, tok, pin, 'answered')
    trace(run, nodeId, pin, 'resume', nil, nil, 'taken by the tester')
    follow(run, nodeId, pin, 0, false, tok.trigger)
    return true
end

--- Back to step `seq`, where the run reached `nodeId`, and on from its `pin` instead of what came after. Every card at
--- work now stops waiting, the cards played after that step may play their Only Once again, and what cards reached
--- after it made is forgotten by the run (so a card can make it again), answered for the caller to take away from the
--- world. Variables, what was handed out and the players stay as they are. What that card made itself stays.
---@return boolean ok
---@return table|string made  { { id = worldId, h = its handle } }, or why not
function R.rewind(run, seq, nodeId, pin)
    if not run or run.status ~= 'running' then return false, 'the run is over' end
    -- Its After cards playing (startAfter): the run has its outcome, its listeners and clock are gone. Over, as a
    -- run that has ended is: no rewind
    if run.after then return false, 'the run is over (its After cards are playing): start the test again' end
    local node = run.graph.nodes[nodeId]
    seq = math.tointeger(tonumber(seq))
    if not seq or not node or not node.def or not node.def._outputs[pin] then return false, 'that is not one of its outcomes' end
    local toks = {}
    for _, tok in pairs(run.active) do toks[#toks + 1] = tok end
    for _, tok in ipairs(toks) do endToken(run, tok, nil, 'rewound') end
    run.active = {}
    run.q = newDeque()
    local ids = {}
    for id, at in pairs(run.madeAt or {}) do
        if at > seq then ids[#ids + 1] = id end
    end
    table.sort(ids)
    local made = {}
    for _, id in ipairs(ids) do
        if type(run.world[id]) == 'table' then made[#made + 1] = { id = id, h = run.world[id] } end
        run.world[id] = nil
        run.madeAt[id] = nil
    end
    for id, at in pairs(run.played) do
        if type(at) == 'number' and at > seq then run.played[id] = nil end
    end
    -- What its ledger holds from after that step, given back (a pile dropped since: CTX:own).
    R.release(run, 'rewound', seq)
    -- The cards' own memory as it was at that step: First Time Only fired after it fires again; Wait for All forgets the
    -- inputs that came after it (its def's rewind).
    local stateAt = run.stateAt or {}
    for id, s in pairs(run.state) do
        local n = run.graph.nodes[id]
        local back = n and n.def and n.def.rewind
        if type(back) == 'function' then
            back(s, seq)
        elseif (stateAt[id] or 0) > seq then
            run.state[id], stateAt[id] = nil, nil
        end
    end
    trace(run, nodeId, pin, 'rewind', nil, nil, ('back to step %d'):format(seq))
    follow(run, nodeId, pin, 0, false, nil)
    return true, made
end

--- A card's ctx for work done from outside the run's pass (a test rewound: what was made, taken away). No activation:
--- it cannot wait.
function R.ctxOf(run, nodeId)
    return setmetatable({ run = run, node = run.graph.nodes[nodeId] or { id = nodeId }, depth = 0 }, CTX)
end

--- The run's last cards, oldest first: { { t, n, node, pin, kind, from, fromPin, text } }.
function R.trace(run)
    local t, out = run.trace, {}
    local first = math.max(1, t.n - L.trace + 1)
    for i = first, t.n do out[#out + 1] = t[((i - 1) % L.trace) + 1] end
    return out
end

local function passInner()
    local now = Ports.now()
    while heap[1] and heap[1].at <= now do
        local w = heapPop()
        if not w.dead then
            if w.watch then
                -- A Fail Condition's look: its rule broken ends the run (or takes a player out) through ctx:broken, here.
                local ok, err = runGuarded(w.watch)
                if not ok then
                    kill(w)
                    fault(w.run, w.node, 'its watch failed: ' .. tostring(err))
                elseif not w.dead and w.run.status == 'running' then
                    w.at = now + math.ceil(w.every)
                    heapPush(w)
                end
            elseif w.poll then
                -- A poll: asked now, and asked again in its time if it is not yet (never sooner, so
                -- this loop cannot go round on one wait).
                local ok, pin, data = runGuarded(w.poll)
                if not ok then
                    kill(w)
                    fault(w.run, w.node, 'its check failed: ' .. tostring(pin))
                elseif pin ~= nil then
                    resolve(w, pin, data)
                else
                    w.at = now + math.ceil(w.every)
                    heapPush(w)
                end
            else
                resolve(w, w.pin)
            end
        end
    end

    local total = 0
    local t0 = Ports.clock()
    local n = #order
    local out = false
    for k = 1, n do
        local run = runs[order[((rr + k - 1) % n) + 1]]
        if run then
            local steps = 0
            while steps < L.perRun and total < L.perPass do
                local p = popFront(run.q)
                if not p then run.burst = 0 break end
                local def = exec(run, p)
                steps, total = steps + 1, total + 1
                if (total % 50 == 0 or (def and def.heavy)) and (Ports.clock() - t0) * 1000 >= L.passMs then out = true break end
                if run.status ~= 'running' then break end
            end
            if run.status == 'running' and dequeEmpty(run.q) then run.burst = 0 end
        end
        if out or total >= L.perPass then break end
    end
    rr = rr + 1

    -- Runs that ran out of time, or have nothing left to wait for, end here.
    now = Ports.now()
    for _, id in ipairs(order) do
        local run = runs[id]
        if run then
            if run.deadlineAt and now >= run.deadlineAt then
                finish(run, 'failed', 'ran out of time')
            elseif run.pre and run.preDeadlineAt and now >= run.preDeadlineAt then
                finish(run, 'aborted', 'the lead-in took too long')
            elseif dequeEmpty(run.q) and run.live <= 0 and not run.open then
                finish(run, 'failed', 'nothing left to wait for: a branch ended without Succeed or Fail')
            end
        end
    end

    local live = {}
    for _, id in ipairs(order) do if runs[id] then live[#live + 1] = id end end
    order = live
    if dirtyEvents then compactEvents() end
    if #heap > 64 then
        local dead = 0
        for _, w in ipairs(heap) do if w.dead then dead = dead + 1 end end
        if dead * 2 > #heap then compactTimers() end
    end

    if #order == 0 then
        heap = {}            -- only ended runs' timers can be left: all dead
        return R.SLEEP_MS
    end
    for _, id in ipairs(order) do
        if not dequeEmpty(runs[id].q) then return 0 end
    end
    while heap[1] and heap[1].dead do heapPop() end
    local soonest = R.IDLE_MS
    if heap[1] then soonest = math.min(soonest, math.max(R.MIN_MS, math.ceil(heap[1].at - Ports.now()))) end
    for _, id in ipairs(order) do
        local r = runs[id]
        for _, d in ipairs({ r.deadlineAt or false, r.pre and r.preDeadlineAt or false }) do
            if d then soonest = math.min(soonest, math.max(R.MIN_MS, math.ceil(d - Ports.now()))) end
        end
    end
    return math.tointeger(soonest) or math.floor(soonest)
end

--- One scheduler pass. Answers how long to sleep before the next (Every's return value): 0 when
--- work is queued, otherwise a whole number of ms, at least MIN_MS.
---@return number ms
function R.pass()
    passing, wakeAsked = true, false
    local ok, res = pcall(passInner)
    passing = false
    if not ok then error(res, 0) end
    return res
end

--- How many waits are held (the harness checks ended runs leave none behind).
function R._counts()
    local events = 0
    for _, list in pairs(eventWaits) do events = events + #list end
    local live = 0
    for _, w in ipairs(heap) do if not w.dead then live = live + 1 end end
    return { timers = #heap, liveTimers = live, events = events }
end

--- Forget everything (the harness; whip_core never calls this).
function R._reset()
    runs, order, rr, nextRunId, nextWaitId, heap, eventWaits, dirtyEvents = {}, {}, 0, 0, 0, {}, {}, false
    holds = {}
    bridged = { ['scenario.started'] = true, ['player.left'] = true }
    passing, wakeAsked = false, false
end
