-- ============================================
-- Director — TestDirectorScenario: a whole scenario run once as a Test, steered and read from a script
-- ============================================
--
-- For a resource's automated tests (whip_test) or a scenario's author: a scenario document built as the editor's
-- Test builds it, run for the player named, and steered the way a tester steers the test map: Take an outcome, say
-- an answer, send an event, set a variable, end it. Nothing of value is kept: Give hands out what the run's end
-- takes back, Pay only says, Charge charges nothing, no script hears of the run, and it skips Runs at once and the
-- cooldown (a Test's own rules: main.lua).
--
--   TestDirectorScenario(doc, opts)    starts it; waits for its end unless opts.wait is false
--   SteerDirectorTest(runId, op, ...)  one of YOUR tests still going: take, say, event, emit, var, end
--   GetDirectorTestResult(runId)       what one of YOUR tests did: kept a while after its end
--
-- A RESULT is plain data: { runId, status ('running' | 'succeeded' | 'failed' | 'aborted' | 'faulted'), reason,
-- faultNode, late (ended for time), vars, steps = { { n, node, kind, pin, text, ms } }, fired = { [node] = { [pin]
-- = times } }, entered = { [node] = times }, waiting = { node, ... }, things = { [worldId] = its handle }, made = {
-- [worldId] = true }, players = { src, ... }, steered, left, done }.

local R = DirectorRuntime
local CORE = GetCurrentResourceName()

local MAX_S = 600                 -- a test's time, at most (seconds)
local DEFAULT_S = 60
local AT_ONCE = 3                 -- a resource's own tests going at a time
local KEEP_MS = 10 * 60 * 1000    -- a result is kept this long after its run ends
local KEEP_MAX = 20               -- results a resource keeps, at most (the oldest go first)
local STEPS_MAX = 4000            -- steps a result keeps; past that they are counted
local STEER_MAX = 200
local EVENT = '^[%a][%w_.:%-]*$'

local tests = {}                  -- [runId] = { owner, src, run, sc, key, result, queue, qi, deadline, endedAt }
local serial = 0

local function say(fmt, ...) print(('[whip_core:director] ' .. fmt):format(...)) end

local finite = DirectorKit.number

--- A plain copy: numbers, text, true/false, vectors as { x, y, z }, tables of those 4 deep.
local function plain(v) return DirectorKit.plain(v, { depth = 4, keys = 100, text = 500 }) end

local function waiting(run)
    local out = {}
    for id, tok in pairs(run.active or {}) do if not tok.dead then out[#out + 1] = id end end
    table.sort(out)
    return out
end

local function isWaiting(run, nodeId)
    local tok = type(nodeId) == 'string' and run.active and run.active[nodeId] or nil
    return tok ~= nil and not tok.dead
end

--- What the result says now: the run as it is, its steps as they came.
local function refresh(t)
    local run, res = t.run, t.result
    res.status, res.reason, res.faultNode = run.status, run.reason, run.faultNode
    res.vars = plain(run.vars) or {}
    res.waiting = run.status == 'running' and waiting(run) or {}
    local players = {}
    for s in pairs(run.players or {}) do players[#players + 1] = s end
    table.sort(players)
    res.players = players
    for wid, h in pairs(run.world or {}) do
        res.things[wid] = plain(h) or true
        res.made[wid] = true
    end
    res.left = #t.queue - t.qi + 1
end

local function note(t, e)
    local res = t.result
    if #res.steps < STEPS_MAX then
        res.steps[#res.steps + 1] = { n = e.n, node = e.node, kind = e.kind, pin = e.pin, text = e.text,
                                      ms = math.max(0, (e.t or 0) - (t.run.startedAt or 0)) }
    else
        res.dropped = (res.dropped or 0) + 1
    end
    if e.node then
        if e.kind == 'enter' then res.entered[e.node] = (res.entered[e.node] or 0) + 1 end
        if (e.kind == 'out' or e.kind == 'resume') and e.pin then
            local f = res.fired[e.node]
            if not f then f = {}; res.fired[e.node] = f end
            f[e.pin] = (f[e.pin] or 0) + 1
        end
    end
end

-- ============================================
-- Steering: what a tester does at the test map
-- ============================================

local OPS = {}

--- take(nodeId, pin): the card waiting there goes on from that outcome, as the test map's Take.
function OPS.take(t, nodeId, pin)
    if not isWaiting(t.run, nodeId) then return false, ('%s is not waiting'):format(tostring(nodeId)) end
    if not R.take(t.run, nodeId, pin) then return false, ('%s has no outcome "%s"'):format(tostring(nodeId), tostring(pin)) end
    return true
end

--- say(nodeId, option, amount?): the tester's answer to the talk that card is having (Dialog Line: opt1..opt4; Haggle:
--- ask with the amount, take, leave; Sell to NPC: yes, no; Pick Team: go), as the card hears it from the capsule.
function OPS.say(t, nodeId, option, amount)
    local run = t.run
    if not isWaiting(run, nodeId) then return false, ('%s is not waiting'):format(tostring(nodeId)) end
    if type(option) ~= 'string' or #option > 32 then return false, 'option is the answer\'s id (opt1, ask, yes...)' end
    if amount ~= nil and not finite(tonumber(amount)) then return false, 'amount is a number' end
    local convId = run.convs and run.convs[t.src] or nil
    R.emit('conversation.choice', { runId = run.id, nodeId = nodeId, convId = convId, source = t.src, option = option,
                                    amount = amount ~= nil and math.floor(tonumber(amount) --[[@as number]]) or nil }, run)
    return true
end

--- event(name, payload?): a script's event into this run, as SendDirectorEvent sends it (Wait for Script Event).
function OPS.event(t, name, payload)
    if type(name) ~= 'string' or #name > 64 or not name:match(EVENT) then return false, 'name is an event\'s name' end
    if payload ~= nil and type(payload) ~= 'table' then return false, 'payload is a table' end
    local p = plain(payload) or {}
    if p.source == nil then p.source = t.src end
    local heard = Director.sendEvent(name, p, { runId = t.run.id }, t.owner, true)
    return true, tonumber(heard) or 0
end

--- emit(name, payload?): one of the Director's own events, heard by this run alone (what the game would have said:
--- 'player.left', 'npc.killed' ...). payload.source is the tester unless said; payload.runId this run.
function OPS.emit(t, name, payload)
    if type(name) ~= 'string' or #name > 64 or not name:match(EVENT) then return false, 'name is an event\'s name' end
    if payload ~= nil and type(payload) ~= 'table' then return false, 'payload is a table' end
    local p = plain(payload) or {}
    if p.source == nil then p.source = t.src end
    if p.runId == nil then p.runId = t.run.id end
    return true, R.emit(name, p, t.run)
end

--- var(name, value): one of the run's variables, now.
function OPS.var(t, name, value)
    if type(name) ~= 'string' or #name > 40 or not name:match('^[%a_][%w_]*$') then return false, 'name is a variable\'s name' end
    local tv = type(value)
    if value ~= nil and tv ~= 'number' and tv ~= 'string' and tv ~= 'boolean' then return false, 'a variable is a number, text or true/false' end
    if tv == 'number' and not finite(value) then return false, 'that is not a number' end
    R.setVar(t.run, name, value)
    return true
end

--- end(outcome?, reason?): over now. 'succeeded' or 'failed' as Succeed or Fail would; anything else aborted.
OPS['end'] = function(t, outcome, reason)
    local why = type(reason) == 'string' and reason:sub(1, 120) or 'ended by its test'
    if outcome == 'succeeded' or outcome == 'failed' then return R.finishRun(t.run.id, outcome, why) end
    return R.abort(t.run.id, why)
end

--- The next of opts.steer, once it can be done: take and say when their card waits, event, emit and var at once
--- or when their `when` card waits; { op = 'wait', ms } holds the list that long.
local function steerNext(t, now)
    local s = t.queue[t.qi]
    if not s then return end
    if s.op == 'wait' then
        s.until_ = s.until_ or (now + (math.tointeger(tonumber(s.ms)) or 0))
        if now < s.until_ then return end
        t.qi = t.qi + 1
        return steerNext(t, now)
    end
    local gate = (s.op == 'take' or s.op == 'say') and s.node or s.when
    if gate ~= nil and not isWaiting(t.run, gate) then return end
    local ok, why
    if s.op == 'take' then ok, why = OPS.take(t, s.node, s.pin)
    elseif s.op == 'say' then ok, why = OPS.say(t, s.node, s.option, s.amount)
    elseif s.op == 'event' then ok, why = OPS.event(t, s.name, s.payload)
    elseif s.op == 'emit' then ok, why = OPS.emit(t, s.name, s.payload)
    elseif s.op == 'var' then ok, why = OPS.var(t, s.name, s.value)
    elseif s.op == 'end' then ok, why = OPS['end'](t, s.outcome, s.reason) end
    t.qi = t.qi + 1
    t.result.steered = t.result.steered + 1
    if ok == false then
        t.result.steerFailed = t.result.steerFailed or {}
        t.result.steerFailed[#t.result.steerFailed + 1] = { i = t.qi - 1, op = s.op, why = tostring(why) }
    end
end

local function queueOf(list)
    if list == nil then return {} end
    if type(list) ~= 'table' then return nil, 'opts.steer is a list of { op = ... }' end
    if #list > STEER_MAX then return nil, ('opts.steer has %d at most'):format(STEER_MAX) end
    local out = {}
    for i, s in ipairs(list) do
        if type(s) ~= 'table' or (s.op ~= 'wait' and not OPS[s.op]) then
            return nil, ('opts.steer[%d]: op is take, say, event, emit, var, end or wait'):format(i)
        end
        local c = {}
        for k, v in pairs(s) do if type(k) == 'string' then c[k] = v end end
        out[i] = c
    end
    return out
end

-- ============================================
-- The run
-- ============================================

local function purge(now)
    local mine = {}
    for id, t in pairs(tests) do
        if t.endedAt and now - t.endedAt > KEEP_MS then tests[id] = nil
        elseif t.endedAt then
            mine[t.owner] = mine[t.owner] or {}
            local l = mine[t.owner]
            l[#l + 1] = t
        end
    end
    for _, l in pairs(mine) do
        if #l > KEEP_MAX then
            table.sort(l, function(a, b) return a.endedAt < b.endedAt end)
            for i = 1, #l - KEEP_MAX do tests[l[i].run.id] = nil end
        end
    end
end

--- Until its end: the steering, the result kept up, its time; then what it made goes.
local function watch(t)
    local run = t.run
    while run.status == 'running' do
        local now = GetGameTimer()
        if now >= t.deadline then
            t.result.late = true
            R.abort(run.id, 'TestDirectorScenario: out of time')
            break
        end
        local ok, err = pcall(steerNext, t, now)
        if not ok then say('^1scripted test %d: steering failed: %s^0', run.id, tostring(err)) t.qi = #t.queue + 1 end
        refresh(t)
        Wait(100)
    end
    refresh(t)
    Registry.releaseTag(CORE, t.sc.tag)
    t.result.done = true
    t.endedAt = GetGameTimer()
end

--- A copy of a result, for its owner.
local function view(t)
    refresh(t)
    return plain(t.result) or {}
end

--- TestDirectorScenario(doc, opts) -> result | false, why
---   doc   a scenario document, as the editor saves it (Check must pass but for a run that can never succeed)
---   opts  { player = <server id> on a character (required: the run is theirs);
---           seconds = 1 to 600 (60): ended (aborted, result.late) when it is still going;
---           vars = { name = value }: set before its first card plays;
---           steer = { { op = 'take', node, pin } | { op = 'say', node, option, amount? } | { op = 'event' | 'emit',
---                     name, payload?, when? } | { op = 'var', name, value, when? } | { op = 'end', outcome?, reason? }
---                     | { op = 'wait', ms } }: done in order, take and say once their card waits, the rest once
---                     their `when` card waits (or at once);
---           wait = false: answer at once (status 'running') and steer it with SteerDirectorTest }
--- WAITS until its end (wait ~= false): call it from a thread.
exports('TestDirectorScenario', function(doc, opts)
    local by = Registry.caller()
    if Director.off then return false, 'The Director is off: ' .. Director.off end
    if type(doc) ~= 'table' then return false, 'a scenario is a document (a table), as the editor saves it' end
    opts = type(opts) == 'table' and opts or {}
    local src = math.tointeger(tonumber(opts.player))
    local p = src and Players[src]
    if not (p and p.charId) then return false, 'opts.player is a player on a character: the test run is theirs' end
    if Director.hasTest(src) then return false, 'that player is testing in the editor: stop it first' end
    local seconds = opts.seconds == nil and DEFAULT_S or math.tointeger(tonumber(opts.seconds))
    if not seconds or seconds < 1 or seconds > MAX_S then return false, ('opts.seconds is 1 to %d'):format(MAX_S) end
    if opts.vars ~= nil and type(opts.vars) ~= 'table' then return false, 'opts.vars is a table of name = value' end
    local queue, qwhy = queueOf(opts.steer)
    if not queue then return false, qwhy end
    local now = GetGameTimer()
    purge(now)
    local mine = 0
    for _, t in pairs(tests) do
        if not t.endedAt then
            if t.owner == by then mine = mine + 1 end
            if t.src == src then return false, 'that player already has a scripted test going' end
        end
    end
    if mine >= AT_ONCE then return false, ('%d scripted tests of yours at a time'):format(AT_ONCE) end

    local okc, passes, probs = pcall(DirectorGraph.check, doc)
    if not okc then return false, 'it could not be checked: ' .. tostring(passes) end
    if not passes and not DirectorGraph.testable(probs) then
        for _, pr in ipairs(probs or {}) do
            if pr.severity == 'error' and not pr.live then return false, 'Check: ' .. tostring(pr.message) end
        end
        return false, 'it does not pass Check'
    end
    serial = serial + 1
    local key = ('scntest:%d'):format(serial)   -- (a colon: never a stored scenario's key)
    local bucket = Director.isolated and Director.isolated[src] or nil
    local sc, bwhy = Director.build(key, doc, { prefix = 'test', bucket = bucket, audience = bucket and { people = { src } } or nil })
    if not sc then return false, bwhy end
    local run, rwhy = Director.startRun(sc, src, { source = src }, { test = true })
    if not run then
        Registry.releaseTag(CORE, sc.tag)
        return false, rwhy
    end
    -- (Before any pass: its first card plays on the next.)
    run.scriptTest = by
    for name, v in pairs(opts.vars or {}) do
        local tv = type(v)
        if type(name) == 'string' and (tv == 'number' or tv == 'string' or tv == 'boolean') then R.setVar(run, name, v) end
    end
    local t = { owner = by, src = src, run = run, sc = sc, key = key, queue = queue, qi = 1,
                deadline = now + seconds * 1000,
                result = { runId = run.id, steps = {}, fired = {}, entered = {}, things = {}, made = {}, steered = 0 } }
    tests[run.id] = t
    for _, e in ipairs(R.trace(run)) do note(t, e) end
    run.onTrace = function(e) note(t, e) end
    say('%s runs a scripted test of "%s" (run %d, for player %d)', by, tostring(doc.name or key), run.id, src)
    CreateThread(function()
        local ok, err = pcall(watch, t)
        if not ok then
            say('^1scripted test %d: %s^0', run.id, tostring(err))
            if run.status == 'running' then R.abort(run.id, 'its test failed') end
            pcall(Registry.releaseTag, CORE, sc.tag)
            t.result.done, t.endedAt = true, GetGameTimer()
        end
    end)
    if opts.wait == false then return view(t) end
    while not t.result.done do Wait(100) end
    return view(t)
end)

--- SteerDirectorTest(runId, op, ...) -> true, extra | false, why. One of your scripted tests still going:
---   'take', nodeId, pin            the card waiting there goes on from that outcome
---   'say', nodeId, option, amount? an answer to the talk that card is having
---   'event', name, payload?        a script's event into it (Wait for Script Event)
---   'emit', name, payload?         one of the Director's own events, heard by it alone
---   'var', name, value             one of its variables
---   'end', outcome?, reason?       over: 'succeeded', 'failed', else aborted
exports('SteerDirectorTest', function(runId, op, ...)
    local by = Registry.caller()
    local t = tests[math.tointeger(tonumber(runId)) or -1]
    if not t or t.owner ~= by then return false, 'no scripted test of yours has that id' end
    if t.run.status ~= 'running' then return false, 'that test is over' end
    local fn = type(op) == 'string' and OPS[op] or nil
    if not fn then return false, 'op is take, say, event, emit, var or end' end
    return fn(t, ...)
end)

--- GetDirectorTestResult(runId) -> result | nil. One of your scripted tests, going or ended (kept 10 minutes).
exports('GetDirectorTestResult', function(runId)
    local by = Registry.caller()
    local t = tests[math.tointeger(tonumber(runId)) or -1]
    if not t or t.owner ~= by then return nil end
    return view(t)
end)

--- Is this run a script's TestDirectorScenario (not a builder's Test)? /director send leaves those alone.
function Director.isScriptTest(run) return type(run) == 'table' and run.scriptTest ~= nil end
