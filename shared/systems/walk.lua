-- ============================================
-- SYSTEMS — the walker: runs switched-on systems
-- ============================================
--
-- Built like the Director runtime (server/director/runtime.lua): everything here is an OBJECT moved
-- by one scheduler pass, never a thread per pulse, under hard limits, because unbounded code on the
-- server thread stops the server. Both lanes use this file: the server's instance of a system, and
-- each player's game's.
--
-- THE PIECES
--   INSTANCE   one switched-on system on this side: its compiled graph, its variables (for everyone,
--              per player, per car), its cards' memory, its pulses. A new GENERATION each time it
--              switches on; every wait carries the generation it was made in.
--   PULSE      one trigger firing ("Bob got in a car"): its context (which player, which car), its
--              open RECEIPTS, and what its cards made. Every branch of the firing shares it.
--   STEP       "run card X from pin P" for a pulse, in a FRAME. Steps wait in the instance's queue;
--              an action's next cards go to the FRONT, so "Do In Order" finishes a branch first.
--   FRAME      where a pulse's values live. The pulse has one; each turn of a For Each / Repeat has
--              its own (its item, its index, what its cards made), so a turn that waits still sees
--              its own item when it carries on.
--   ACTIVATION a waiting card in one pulse and frame (Delay, Charge): its waits (a timer, an event,
--              a poll, a CALL: a thread for an API call that waits). The first to answer wins.
--
-- VALUES are PULLED when a card runs: a value card (Formula, Distance) is worked out then, from its own
-- inputs; an action's output (the car it made) is read from the frame. Once per card step, and again
-- each time a card that reads it runs: every loop turn, after every wait.
--
-- MONEY IS THE WALKER'S. A card that takes a payment hands it to ctx:receipt(undo).
-- The walker then owns it, and does exactly one thing with it, once:
--   SETTLED (kept for good)   the pulse ends normally, or a card answers one of its `settles` pins
--                             (Give Item's Given: what was paid for was delivered)
--   UNDONE (refunded)         the pulse is cancelled, dropped, refused or errors before that; or the
--                             receipt arrives after its card stopped waiting (a timeout won)
-- Cards never refund money in onCancel or a late handler.
--
-- LIMITS (LIMITS below; Config.Systems can change them). Nothing a builder wires can run unbounded:
--   chain        500 cards in a row without a real pause ends the pulse (a loop); a pulse a card's own
--                action set off counts from that card (a system feeding itself)
--   steps        5000 cards in one pulse, 100 wake-ups a second, an hour of life
--   budget       each card (and each poll) costs points: a player's pulses 200 a second, a system
--                6000, every system together 10000. Over a share, the pulse is dropped AT ITS NEXT
--                STEP (never half-way through a card); over the system's or everyone's, the system
--                also pauses 10 s (its queue and waits keep, its triggers are dropped and counted)
--   pulses       8 at once per player, 512 per system; waits 16 per pulse, 1024 per system
--   pass         1000 steps, 500 timers and about 2 ms of wall time per pass, round-robin
--   errors       FAULT (switched off with the reason): of the pulses that ENDED in the last minute,
--                at least 20 ended and 10 errors and over 5% of them errors. A missing value or a
--                formula that cannot be worked out is REFUSED, not an error
--
-- Side effects leave only through PORTS, so a test harness can drive every rule with a fake clock and
-- fake threads (R.setPorts).

SystemsRuntime = {
    LIMITS = {
        chain = 500, quickMs = 100, pulseSteps = 5000, resumesPerSec = 100, pulseLifeMs = 3600 * 1000,
        perInstance = 200, perPass = 1000, timersPerPass = 500, passMs = 2.0,
        budget = 6000, playerBudget = 200, serverBudget = 10000, pauseMs = 10000,
        pulsesPerPlayer = 8, pulsesPerSystem = 512, waitsPerPulse = 16, waitsPerSystem = 1024,
        errorRate = 0.05, errorMin = 20, errorCount = 10, errorWindowSec = 60,
        minWaitMs = 50, maxWaitMs = 7 * 24 * 3600 * 1000, minTimerMs = 250,
        pollMinMs = 250, valueDepth = 32, frameDepth = 16, trace = 200, log = 100, rememberText = 200,
    },
    -- IDLE_MS: the longest a pass sleeps while a system is on and nothing is due; SLEEP_MS while none
    -- is on. Only backstops: work queued and a system switched on wake it (wake), and a timer or poll
    -- sets the sleep itself (the pass's answer, which server/systems/main.lua honours for a pass a wake
    -- ran too).
    IDLE_MS = 1000, SLEEP_MS = 5000, MIN_MS = 10,
}
local R = SystemsRuntime
local L = R.LIMITS
local C = SystemCards

local Ports = {
    now = function() return GetGameTimer() end,
    clock = os.clock,
    thread = function(fn) CreateThread(fn) end,
    threadNow = function(fn) Citizen.CreateThreadNow(fn) end,
    wake = nil,          -- fn(): run a pass soon; nil = the loop's own pace
    log = function(msg) print('[whip_core:systems] ' .. msg) end,
    onStop = nil,        -- fn(inst, outcome, why): release its tag, undo its ledger
    session = nil,       -- fn(src): that player's current session, or nil (gone). REQUIRED: unset, every player is refused
    charOf = nil,        -- fn(player): their charId, or nil when player.session is not their current one
    remember = nil,      -- fn(inst, scope, key, name, value): a remembered variable changed
    onPulseEnd = nil,    -- fn(inst, pulse, outcome, why)
    players = nil,       -- fn(): every loaded player now, as { { source, session }, ... } (per-player timers)
}

--- Swap the side effects (the harness, and the Systems' start-up wiring).
function R.setPorts(p) for k, v in pairs(p) do Ports[k] = v end end

local instances = {}   -- [instId] = instance, switched on
local order = {}       -- instance ids, for the round-robin
local rr = 0
local nextInst, nextPulse, nextFrame, nextWait, nextReceipt, tokSeq = 0, 0, 0, 0, 0, 0
local heap = {}        -- timer, poll and trigger-timer waits: a min-heap on (at, id)
local eventWaits = {}  -- [name] = { wait, ... } (Wait Until ... cards)
local bridged = {}     -- names a card may wait for (R.bridge)
local dirtyEvents = false
local passing, wakeAsked = false, false
local current = nil    -- the step running now: { inst, pulse, depth } (a pulse it sets off counts from it)
local gone = {}        -- players and cars that left, handled at the start of the next pass
local server = { at = 0, used = 0 }   -- every system's points this second
-- WHO IS TESTING WHAT: [system key] = { [server id] = { n = tests going, from = the last pulse before
-- the first began } }. While you test a draft of a system, its switched-on copy IGNORES you: it starts
-- nothing for you, and its pulses started since act on you in nothing, so a test is never two systems
-- at once. Pulses already going when the test began finish as they began.
local testing = {}

-- ============================================
-- Small parts
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

local copy = C.copy

--- An error's words: a card's bad() / refuse() table, or anything else as text.
local function errText(e)
    if type(e) == 'table' then
        if type(e.systems) == 'string' then return e.systems end
        return 'it failed'
    end
    return tostring(e)
end
local function isRefusal(e) return type(e) == 'table' and e.refused == true end

--- Run card code so that a WAIT inside it is caught instead of stalling the pass.
local function runGuarded(fn, ...)
    if type(fn) ~= 'function' then return false, { systems = 'it has nothing to run' } end
    local co = coroutine.create(fn)
    local r = table.pack(coroutine.resume(co, ...))
    if coroutine.status(co) ~= 'dead' then
        pcall(coroutine.close, co)
        return false, { systems = 'it waited inside the scheduler (anything that waits goes in ctx:call)' }
    end
    return table.unpack(r, 1, r.n)
end

local function wake()
    if passing or wakeAsked or not Ports.wake then return end
    wakeAsked = true
    local ok, err = pcall(Ports.wake)
    if not ok then wakeAsked = false; Ports.log('wake failed: ' .. tostring(err)) end
end

local function logTo(inst, level, nodeId, msg)
    local l = inst.log
    l.n = l.n + 1
    l[((l.n - 1) % L.log) + 1] = { t = Ports.now(), level = level, node = nodeId, msg = msg }
    if level == 'error' or inst.echo then
        Ports.log(('%s%s card %s: %s'):format(inst.key, inst.test and ' [TEST]' or '', tostring(nodeId), msg))
    end
end

--- One line of what ran. An 'enter' says the wire it came along (`from`, `fromPin`), so the
--- editor's Test lights that wire as well as the card.
local function trace(inst, pulse, nodeId, pin, kind, from, fromPin)
    local t = inst.trace
    t.n = t.n + 1
    local e = { t = Ports.now(), pulse = pulse and pulse.id, node = nodeId, pin = pin, kind = kind, from = from, fromPin = fromPin }
    t[((t.n - 1) % L.trace) + 1] = e
    if inst.onTrace then
        local ok, err = pcall(inst.onTrace, e, inst)
        if not ok then inst.onTrace = nil; logTo(inst, 'error', nodeId, 'its trace watcher failed: ' .. tostring(err)) end
    end
end

local function idKey(v) return tostring(math.tointeger(tonumber(v) or 0) or v) end

-- ============================================
-- The error window: pulses that ENDED, per second, for a minute
-- ============================================

local function bucket(inst)
    local sec = Ports.now() // 1000
    local b = inst.win[(sec % L.errorWindowSec) + 1]
    if b.sec ~= sec then b.sec, b.ended, b.errors = sec, 0, 0 end
    return b
end

local stopInstance

local function windowTotals(inst)
    local sec = Ports.now() // 1000
    local ended, errors = 0, 0
    for _, b in ipairs(inst.win) do
        if b.sec and sec - b.sec < L.errorWindowSec then ended, errors = ended + b.ended, errors + b.errors end
    end
    return ended, errors
end

local function noteEnded(inst, isError)
    local b = bucket(inst)
    b.ended = b.ended + 1
    if not isError then return end
    b.errors = b.errors + 1
    inst.errors = inst.errors + 1
    local ended, errors = windowTotals(inst)
    if errors >= L.errorCount and ended >= L.errorMin and errors / ended > L.errorRate then
        stopInstance(inst, 'faulted', ('%d of the last %d pulses ended in an error'):format(errors, ended))
    end
end

-- ============================================
-- Budgets (marked now, dropped at the step's end: never half-way through a card)
-- ============================================

local function playerOf(pulse)
    local p = pulse and pulse.ctx.player
    return p and p.source or nil
end

local function paused(inst) return inst.pausedUntil ~= nil and Ports.now() < inst.pausedUntil end

local function pauseInstance(inst, why)
    if paused(inst) then return end
    inst.pausedUntil = Ports.now() + L.pauseMs
    inst.pauses = inst.pauses + 1
    logTo(inst, 'error', nil, ('paused for %d s: %s'):format(L.pauseMs // 1000, why))
end

--- Spend `cost` for this pulse. A pulse over a share is MARKED (pulse.over) and dropped by the
--- walker at its next step boundary; the system over its own or everyone's also pauses.
local function spend(inst, pulse, cost)
    local now = Ports.now()
    if now - server.at >= 1000 then server.at, server.used = now, 0 end
    server.used = server.used + cost
    local b = inst.budget
    if now - b.at >= 1000 then b.at, b.used = now, 0 end
    b.used = b.used + cost
    if b.used > L.budget or server.used > L.serverBudget then
        pauseInstance(inst, b.used > L.budget and ('too busy: more than %d points in a second'):format(L.budget)
            or ('every system together is over %d points a second'):format(L.serverBudget))
        if pulse and not pulse.over then pulse.over = 'the system was too busy' end
        return
    end
    local src = playerOf(pulse)
    if src then
        local pb = inst.playerBudget[src]
        if not pb or now - pb.at >= 1000 then pb = { at = now, used = 0 }; inst.playerBudget[src] = pb end
        pb.used = pb.used + cost
        if pb.used > L.playerBudget and not pulse.over then
            pulse.over = ("one player's share is %d points a second"):format(L.playerBudget)
        end
    end
end

-- ============================================
-- Receipts (the walker's: settled or undone exactly once)
-- ============================================

local receipts = {}   -- [id] = { id, inst, pulse, undo, state = 'open' }

local function runUndo(rec, why)
    if rec.state ~= 'open' then return end
    rec.state = 'undone'
    receipts[rec.id] = nil
    local inst = rec.inst
    Ports.threadNow(function()
        local ok, err = pcall(rec.undo, why)
        if not ok then logTo(inst, 'error', rec.node, 'its refund failed: ' .. tostring(err)) end
    end)
end

local function settleReceipts(pulse)
    for _, rec in ipairs(pulse.receipts) do
        if rec.state == 'open' then rec.state = 'settled'; receipts[rec.id] = nil end
    end
    pulse.receipts = {}
end

-- ============================================
-- Pulses, frames, ends
-- ============================================

local function newFrame(parent, loopNode)
    nextFrame = nextFrame + 1
    return { id = nextFrame, parent = parent, out = {}, loopNode = loopNode,
             depth = parent and (parent.depth + 1) or 0 }
end

local function frameGet(frame, nodeId, key)
    local f = frame
    while f do
        local o = f.out[nodeId]
        if o and o[key] ~= nil then return o[key] end
        f = f.parent
    end
    return nil
end

local function kill(w)
    if w.dead then return end
    w.dead = true
    if w.pulse then
        w.pulse.pending = w.pulse.pending - 1
        w.pulse.waits = w.pulse.waits - 1
    end
    if w.inst and w.counts then w.inst.liveWaits = w.inst.liveWaits - 1 end
    if w.event then dirtyEvents = true end
    -- Nothing reaches back through a dead wait (drop its references to the pulse and frame).
    w.frame, w.poll, w.filter = nil, nil, nil
end

local function endToken(tok, pin, why)
    if tok.dead then return end
    tok.dead = true
    for _, w in ipairs(tok.waits) do kill(w) end
    if tok.pulse.active[tok.key] == tok then tok.pulse.active[tok.key] = nil end
    if tok.onEnd then
        local inst = tok.pulse.inst
        for _, fn in ipairs(tok.onEnd) do
            Ports.threadNow(function()
                local ok, err = pcall(fn, pin, why)
                if not ok then logTo(inst, 'error', tok.node, 'its end hook failed: ' .. tostring(err)) end
            end)
        end
    end
end

local function pulseLeft(inst, pulse)
    inst.pulseCount = inst.pulseCount - 1
    local src = playerOf(pulse)
    if src then
        local n = (inst.perPlayer[src] or 1) - 1
        inst.perPlayer[src] = n > 0 and n or nil
    end
    inst.pulses[pulse.id] = nil
end

--- A pulse is over: 'done', 'cancelled', 'dropped', 'refused' or 'error'. Its waits die. Done
--- SETTLES its receipts (the money is kept); every other end UNDOES them (refunds) and runs its
--- cancel hooks.
local function endPulse(pulse, outcome, why, nodeId)
    if pulse.status ~= 'running' then return end
    local inst = pulse.inst
    pulse.status = outcome
    local toks = {}
    for _, tok in pairs(pulse.active) do toks[#toks + 1] = tok end
    table.sort(toks, function(a, b) return a.seq < b.seq end)
    for _, tok in ipairs(toks) do endToken(tok, nil, outcome == 'done' and 'pulse ended' or outcome) end
    pulseLeft(inst, pulse)
    if outcome == 'done' then
        settleReceipts(pulse)
    else
        local list = pulse.receipts
        pulse.receipts = {}
        for i = #list, 1, -1 do runUndo(list[i], outcome) end
        for i = #pulse.cancelHooks, 1, -1 do
            local fn = pulse.cancelHooks[i]
            Ports.threadNow(function()
                local ok, err = pcall(fn, outcome, why)
                if not ok then logTo(inst, 'error', nodeId, 'a cancel hook failed: ' .. tostring(err)) end
            end)
        end
    end
    pulse.cancelHooks = {}
    if outcome == 'error' then
        logTo(inst, 'error', nodeId, tostring(why))
    elseif why and outcome ~= 'done' then
        logTo(inst, outcome == 'refused' and 'warn' or 'info', nodeId, ('%s: %s'):format(outcome, tostring(why)))
    end
    if Ports.onPulseEnd then pcall(Ports.onPulseEnd, inst, pulse, outcome, why) end
    noteEnded(inst, outcome == 'error')
end

local function maybeDone(pulse)
    if pulse.status == 'running' and pulse.pending <= 0 then endPulse(pulse, 'done') end
end

local function pulseError(pulse, nodeId, msg)
    endPulse(pulse, 'error', msg, nodeId)
end

--- A pulse marked over budget goes now (between steps).
local function dropIfOver(pulse)
    if pulse.status == 'running' and pulse.over then
        pulse.inst.dropped.budget = pulse.inst.dropped.budget + 1
        endPulse(pulse, 'dropped', pulse.over)
        return true
    end
    return false
end

-- ============================================
-- Following wires
-- ============================================

local function follow(inst, pulse, nodeId, pin, depth, front, frame)
    local byPin = inst.graph.execOut[nodeId]
    local targets = byPin and byPin[pin]
    if not targets then return end
    if front then
        for i = #targets, 1, -1 do
            pulse.pending = pulse.pending + 1
            pushFront(inst.q, { pulse = pulse, node = targets[i].node, pin = targets[i].pin, depth = depth, frame = frame,
                                from = nodeId, fromPin = pin })
        end
    else
        for i = 1, #targets do
            pulse.pending = pulse.pending + 1
            pushBack(inst.q, { pulse = pulse, node = targets[i].node, pin = targets[i].pin, depth = depth, frame = frame,
                               from = nodeId, fromPin = pin })
        end
        wake()
    end
end

--- A pin's last value, for the editor's Test (hover a pin): kept per card and per pin (a card's pins
--- share one name space, so an input and an output never take each other's place), each value its own
--- bounded copy; one too big to copy is said to be.
local function noteValue(inst, nodeId, key, value)
    if not inst.watchValues then return end
    local lv = inst.lastValues[nodeId]
    if not lv then lv = {}; inst.lastValues[nodeId] = lv end
    local c = copy(value)
    if c == nil and value ~= nil then c = '(too big to show)' end
    lv[key] = c
end

--- Store a card's value outputs into a frame. Answers true, or false and why (a check that failed:
--- the caller ends the pulse; nothing here may throw into the pass).
local function storeOutputs(inst, node, frame, outs)
    if type(outs) ~= 'table' then return true end
    local ok, err = pcall(function()
        local o = frame.out[node.id]
        if not o then o = {}; frame.out[node.id] = o end
        for key, pinRec in pairs(node.vout) do
            if outs[key] ~= nil then
                o[key] = C.coerce(pinRec.type, outs[key], Ports.charOf)
                noteValue(inst, node.id, key, o[key])
            end
        end
    end)
    if not ok then return false, 'its values could not be kept: ' .. errText(err) end
    return true
end

--- Settle the pulse's receipts when a card answers a pin that means "delivered".
local function maybeSettle(pulse, def, pins)
    if not next(def._settles) then return end
    for i = 1, #pins do
        if def._settles[pins[i]] then settleReceipts(pulse) return end
    end
end

--- A wait answered with `pin` and (optionally) the card's value outputs.
local function resolve(w, pin, outs)
    if w.dead then return false end
    local inst, pulse = w.inst, w.pulse
    if inst.status ~= 'on' or w.gen ~= inst.gen or pulse.status ~= 'running' then kill(w) return false end
    local node = inst.graph.nodes[w.node]
    if not node.def._outputs[pin] then
        kill(w)
        pulseError(pulse, w.node, ('a wait answered "%s", which this card does not have'):format(tostring(pin)))
        return false
    end
    -- A loop through a quick wait, or a call that answers again and again: count the wake-ups.
    local t = Ports.now()
    if t - pulse.rateAt >= 1000 then pulse.rateAt, pulse.rate = t, 0 end
    pulse.rate = pulse.rate + 1
    if pulse.rate > L.resumesPerSec then
        kill(w)
        pulseError(pulse, w.node, ('runaway: woken more than %d times in a second'):format(L.resumesPerSec))
        return false
    end
    local d = (t - (w.made or -math.huge) < L.quickMs) and ((w.depth or 0) + 1) or 0
    local frame = w.frame
    if w.persistent then
        if w.once then kill(w) end
    else
        endToken(w.token, pin, 'answered')
    end
    local ok, why = storeOutputs(inst, node, frame, outs)
    if not ok then pulseError(pulse, w.node, why) return false end
    maybeSettle(pulse, node.def, { pin })
    trace(inst, pulse, w.node, pin, 'resume')
    follow(inst, pulse, w.node, pin, d, false, frame)
    maybeDone(pulse)
    return true
end

-- ============================================
-- What a card's code is handed (ctx)
-- ============================================

local CTX = {}
CTX.__index = CTX

local function bad(msg) error({ systems = msg }, 0) end
local function refuse(msg) error({ systems = msg, refused = true }, 0) end

local function scopeKeyOf(ctx, scope)
    if scope == nil or scope == 'everyone' then return 'e' end
    local pulse = ctx.pulse
    if scope == 'player' then
        local p = pulse and pulse.ctx.player
        if not p then return nil, 'this is kept per player, and nothing here says which player' end
        local cid = pulse.ctx.char
        if not cid and Ports.charOf then
            local ok, got = pcall(Ports.charOf, p)
            cid = ok and C.id(got) or nil
        end
        if not cid then return nil, 'this is kept per player, and that player is no longer here' end
        pulse.ctx.char = cid
        return 'p:' .. idKey(cid), cid
    elseif scope == 'car' then
        local v = pulse and pulse.ctx.vehicle
        if not v then return nil, 'this is kept per car, and nothing here says which car' end
        return 'v:' .. idKey(v), v
    end
    return nil, 'unknown scope ' .. tostring(scope)
end

--- A field's value, or its default. Tables are copies: the compiled graph is shared.
function CTX:prop(key)
    local v = self.node.props[key]
    if v == nil then
        local f = self.node.def._fields[key]
        if f then v = f.default end
    end
    return copy(v)
end

--- Something worked out once per card in the compiled graph (a Formula's parsed line), kept on it.
function CTX:cached(key, fn)
    local c = self.node.cache
    local v = c[key]
    if v == nil then
        local a, b = fn()
        v = { a, b }
        c[key] = v
    end
    return v[1], v[2]
end

local evalValue

--- A value input: from its wire (a value card worked out now, or what an earlier card made), its
--- typed-in constant, or its default. nil when it has none; a wrong type answers nil too.
function CTX:input(key)
    local node = self.node
    local pin = node.vin[key]
    if not pin then bad(('%s has no value input called %s'):format(node.type, tostring(key))) end
    -- Inside a call thread a value is worked out fresh each time: the step's are from before it waited.
    if self.fresh then self.memo = {} end
    local src = self.inst.graph.valueIn[node.id]
    src = src and src[key]
    local v
    if src then
        local sn = self.inst.graph.nodes[src.node]
        if sn.def.kind == 'value' then
            v = evalValue(self, sn, src.pin)
        else
            v = frameGet(self.frame, src.node, src.pin)
        end
    else
        v = node.consts[key]
        if v == nil then v = pin.default end
    end
    local got = C.coerce(pin.type, v, Ports.charOf)
    noteValue(self.inst, node.id, key, got)
    return got
end

--- A value input the card cannot do without: its value, or the pulse is REFUSED with why (a player
--- on foot has no car; a formula divided by 0): logged, not an error.
function CTX:need(key)
    local v = self:input(key)
    if v == nil then refuse(('"%s" has no value'):format(self.node.vin[key] and self.node.vin[key].label or key)) end
    return v
end

--- Give a value output its value now (an action's: what it made, what it read). The wrong type is an
--- error, never a quiet nil.
function CTX:set(key, value)
    local pin = self.node.vout[key]
    if not pin then bad(('%s has no value output called %s'):format(self.node.type, tostring(key))) end
    if self.pulse and self.pulse.status ~= 'running' then return end
    local got = C.coerce(pin.type, value, Ports.charOf)
    if got == nil and value ~= nil then bad(('%s: that is not a %s'):format(pin.label, pin.type)) end
    local o = self.frame.out[self.node.id]
    if not o then o = {}; self.frame.out[self.node.id] = o end
    o[key] = got
    noteValue(self.inst, self.node.id, key, got)
end

evalValue = function(ctx, sn, pinKey)
    local memo = ctx.memo
    local outs = memo[sn.id]
    if outs == nil then
        local depth = (ctx.vdepth or 0) + 1
        if depth > L.valueDepth then bad('values wired more than 32 deep') end
        if memo[sn.id .. ':busy'] then bad('values wired in a loop') end
        memo[sn.id .. ':busy'] = true
        spend(ctx.inst, ctx.pulse, sn.def.cost)
        local vctx = setmetatable({ inst = ctx.inst, pulse = ctx.pulse, node = sn, frame = ctx.frame, memo = memo,
                                    vdepth = depth, depth = ctx.depth }, CTX)
        local ok, res, why = runGuarded(sn.def.value, vctx)
        memo[sn.id .. ':busy'] = nil
        if not ok then
            if type(res) == 'table' and res.systems ~= nil then error(res, 0) end
            bad(('%s: %s'):format(sn.def.title, errText(res)))
        end
        if res == nil then
            -- A value card that could not answer (a formula's division by 0): the inputs it feeds
            -- have no value, and the log says why.
            if why then logTo(ctx.inst, 'warn', sn.id, tostring(why)) end
            outs = false
        else
            if type(res) ~= 'table' then bad(sn.def.title .. ' answered something that is not its values') end
            outs = {}
            for key, pin in pairs(sn.vout) do outs[key] = C.coerce(pin.type, res[key], Ports.charOf) end
        end
        memo[sn.id] = outs
        if outs then for key, v in pairs(outs) do noteValue(ctx.inst, sn.id, key, v) end end
    end
    if not outs then return nil end
    return outs[pinKey]
end

--- The pulse's player ({ source, session }) and car (a vehicleId), when its trigger said. Act on a
--- player only through ctx:source(p).
function CTX:player() return self.pulse and copy(self.pulse.ctx.player) end
function CTX:vehicle() return self.pulse and self.pulse.ctx.vehicle end

--- A player value's server id, if they are still the same session (a player kept across a wait may
--- have relogged as someone else). In a Test, only the tester. Fails closed: no session on the value,
--- or no way to ask, refuses. nil and why.
function CTX:source(p)
    if type(p) ~= 'table' or p.source == nil then return nil, 'no player' end
    if self.inst.only and p.source ~= self.inst.only then return nil, 'a test acts only on the tester' end
    local tt = not self.inst.test and testing[self.inst.key] and testing[self.inst.key][p.source]
    if tt and (not self.pulse or self.pulse.id > tt.from) then
        return nil, 'that player is testing a draft of this system'
    end
    if not Ports.session then return nil, 'nothing can say who is here' end
    if p.session == nil then return nil, 'that player value does not say which session it is from' end
    local s = Ports.session(p.source)
    if s == nil then return nil, 'that player is no longer here' end
    if s ~= p.session then return nil, 'that player has logged in as someone else' end
    return p.source
end

--- A variable, as its scope keeps it for this pulse (a copy).
function CTX:var(name)
    local decl = self.inst.graph.vars[name]
    if not decl then bad(('there is no variable called %s'):format(tostring(name))) end
    local key, why = scopeKeyOf(self, decl.scope)
    if not key then refuse(why) end
    local store = self.inst.vars[key]
    local v = store and store[name]
    if v == nil then v = decl.default end
    if v == nil then v = C.zero(decl.type) end
    return copy(v)
end

--- Set a variable, as its scope keeps it for this pulse. A value of the wrong type is refused. A
--- pulse that is over sets nothing (a call that answered after its pulse was cancelled).
function CTX:setVar(name, value)
    local decl = self.inst.graph.vars[name]
    if not decl then bad(('there is no variable called %s'):format(tostring(name))) end
    if self.pulse and self.pulse.status ~= 'running' then return end
    local key, why = scopeKeyOf(self, decl.scope)
    if not key then refuse(why) end
    ---@cast key -nil   -- refuse() throws
    local v = C.coerce(decl.type, value, Ports.charOf)
    if v == nil and value ~= nil then bad(('%s holds a %s, and that is not one'):format(name, decl.type)) end
    if decl.remember and decl.type == 'text' and v and #v > L.rememberText then
        bad(('%s is remembered, so it holds %d characters at most'):format(name, L.rememberText))
    end
    local store = self.inst.vars[key]
    if not store then store = {}; self.inst.vars[key] = store end
    store[name] = v
    if decl.remember and Ports.remember then
        local ok, err = pcall(Ports.remember, self.inst, decl.scope or 'everyone', key, name, copy(v))
        if not ok then logTo(self.inst, 'error', self.node.id, 'remembering it failed: ' .. tostring(err)) end
    end
end

--- This card's own memory, for everyone or per player / car (First Time Only, Cooldown, Gate). Per
--- player it is the CHARACTER's, and lasts while the system is on: a relog does not start it over
--- (so "first visit pays" can't be farmed by relogging).
function CTX:state(scope)
    local key, why = scopeKeyOf(self, scope)
    if not key then refuse(why) end
    ---@cast key -nil   -- refuse() throws
    local byNode = self.inst.state[self.node.id]
    if not byNode then byNode = {}; self.inst.state[self.node.id] = byNode end
    local s = byNode[key]
    if not s then s = {}; byNode[key] = s end
    return s
end

function CTX:tag() return self.inst.tag end
--- In an editor's Test, the tester's server id (what a card shows to "everyone" goes to them alone);
--- nil when the system is switched on for real.
function CTX:tester() return self.inst.test and self.inst.only or nil end
--- Which switched-on instance and card this is: a trigger's match tells its own moments from another
--- instance's (a Point Used card's press names the instance and card whose point it was).
function CTX:instanceId() return self.inst.id end
function CTX:nodeId() return self.node.id end
function CTX:now() return Ports.now() end
--- What the system is (its name, short id, revision, money owner): what a card writes beside a
--- payment or an item in the activity log. A copy.
function CTX:meta() return copy(self.inst.meta) or {} end
function CTX:log(fmt, ...)
    logTo(self.inst, 'info', self.node.id, select('#', ...) > 0 and tostring(fmt):format(...) or tostring(fmt))
end

--- Hand the walker a payment this card took: `undo(why)` refunds it. Answers the receipt value
--- ({ receipt = n }, for a receipt output pin), or nil when the pulse or this card's activation is
--- already over: then it is refunded at once (a payment that landed after a timeout won).
function CTX:receipt(undo)
    if type(undo) ~= 'function' then bad('a receipt needs its refund') end
    nextReceipt = nextReceipt + 1
    local rec = { id = nextReceipt, inst = self.inst, pulse = self.pulse, undo = undo, state = 'open', node = self.node.id }
    receipts[rec.id] = rec
    local pulse = self.pulse
    if not pulse or pulse.status ~= 'running' or (self.token and self.token.dead) then
        runUndo(rec, 'too late')
        return nil
    end
    pulse.receipts[#pulse.receipts + 1] = rec
    return { receipt = rec.id }
end

--- Is this receipt value one of THIS pulse's, still open? (A Refund card asks before refunding.)
function CTX:ownReceipt(v)
    local id = type(v) == 'table' and C.id(v.receipt) or nil
    local rec = id and receipts[id]
    if not rec or rec.pulse ~= self.pulse or rec.state ~= 'open' then return nil end
    return rec
end

--- Refund one of this pulse's receipts now (a Refund card). Answers true, or false and why.
function CTX:undoReceipt(v)
    local rec = self:ownReceipt(v)
    if not rec then return false, 'that is not a payment this pulse is holding' end
    for i, r in ipairs(rec.pulse.receipts) do if r == rec then table.remove(rec.pulse.receipts, i) break end end
    runUndo(rec, 'refunded')
    return true
end

--- Refund one of this pulse's receipts and WAIT for it (a Refund card, inside its ctx:call): true, or
--- false and why. Closed first, so the pulse ending meanwhile never refunds it a second time; tried
--- once, and the answer says whether it really ran.
function CTX:refundNow(v)
    local rec = self:ownReceipt(v)
    if not rec then return false, 'that is not a payment this pulse is holding' end
    for i, r in ipairs(rec.pulse.receipts) do if r == rec then table.remove(rec.pulse.receipts, i) break end end
    rec.state = 'undone'
    receipts[rec.id] = nil
    local ok, err = pcall(rec.undo, 'refunded')
    if not ok then
        logTo(rec.inst, 'error', rec.node, 'its refund failed: ' .. tostring(err))
        return false, errText(err)
    end
    return true
end

--- Run a pin once per turn: `turns` = { { [outputKey] = value, ... }, ... } (100 at most). Each turn
--- gets its own frame holding those values, and runs to its end (or its first wait) before the
--- next; then `donePin` runs in this card's own frame. A loop card entered again from inside one of
--- its own turns starts its new turns beside them, not inside (or the frames would nest forever).
function CTX:loop(pin, turns, donePin)
    if self.looped then bad('a card loops once per run') end
    self.looped = true
    local n = math.min(#turns, C.MAX_TURNS)
    local inst, pulse, node = self.inst, self.pulse, self.node
    local base = self.frame
    while base.loopNode == node.id and base.parent do base = base.parent end
    if base.depth + 1 > L.frameDepth then bad(('loops inside loops, more than %d deep'):format(L.frameDepth)) end
    if donePin then follow(inst, pulse, node.id, donePin, self.depth + 1, true, base) end
    for i = n, 1, -1 do
        local f = newFrame(base, node.id)
        local o = {}
        for key, pinRec in pairs(node.vout) do
            if turns[i][key] ~= nil then o[key] = C.coerce(pinRec.type, turns[i][key], Ports.charOf) end
        end
        f.out[node.id] = o
        follow(inst, pulse, node.id, pin, self.depth + 1, true, f)
    end
end

--- Run this hook if the pulse is cancelled, dropped, refused or errors (to put away what the card
--- made: never money, which goes through ctx:receipt). One asked for when the pulse is already over
--- runs at once.
function CTX:onCancel(fn)
    if type(fn) ~= 'function' then bad('onCancel takes a function') end
    local pulse = self.pulse
    if not pulse or pulse.status ~= 'running' then
        Ports.threadNow(function() pcall(fn, 'cancelled', 'already over') end)
        return
    end
    pulse.cancelHooks[#pulse.cancelHooks + 1] = fn
end

local function newWait(ctx, kind)
    local tok = ctx.token
    if not tok then bad('only a waiting card can wait (kind = "wait")') end
    if tok.dead or ctx.pulse.status ~= 'running' then return nil end
    if ctx.pulse.waits >= L.waitsPerPulse then bad(('a pulse waits on %d things at most'):format(L.waitsPerPulse)) end
    if ctx.inst.liveWaits >= L.waitsPerSystem then bad(('a system waits on %d things at most'):format(L.waitsPerSystem)) end
    nextWait = nextWait + 1
    local w = { id = nextWait, inst = ctx.inst, gen = ctx.inst.gen, pulse = ctx.pulse, node = ctx.node.id,
                kind = kind, token = tok, frame = ctx.frame, depth = ctx.depth, made = Ports.now(), counts = true }
    tok.waits[#tok.waits + 1] = w
    ctx.pulse.pending = ctx.pulse.pending + 1
    ctx.pulse.waits = ctx.pulse.waits + 1
    ctx.inst.liveWaits = ctx.inst.liveWaits + 1
    return w
end

--- Continue from `pin` in `ms` (50 ms to a week).
function CTX:after(ms, pin)
    if not self.node.def._outputs[pin] then bad(('"%s" is not one of this card\'s pins'):format(tostring(pin))) end
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

--- Continue when fn(ctx) answers a pin (and optionally its outputs), asked every `ms` (at least
--- 250). fn must not wait; a value it reads is worked out fresh on every ask; each ask costs a point.
function CTX:poll(ms, fn)
    if type(fn) ~= 'function' then bad('poll takes a function') end
    local w = newWait(self, 'poll')
    if not w then return nil end
    local n = tonumber(ms) or 1000
    if n ~= n then n = 1000 end
    w.every = math.max(n, L.pollMinMs)
    w.poll = fn
    w.at = Ports.now() + math.ceil(w.every)
    heapPush(w)
    return w.id
end

--- Continue when `name` is told to the systems (R.emit) and filter(payload) answers a pin (and
--- optionally outputs); nil = not this one. The name must be one the systems hear (R.bridge).
function CTX:on(name, filter)
    if not bridged[name] then bad(('nothing tells the systems "%s"'):format(tostring(name))) end
    if type(filter) ~= 'function' then bad('on takes a function') end
    local w = newWait(self, 'event')
    if not w then return nil end
    w.event, w.filter = name, filter
    local list = eventWaits[name]
    if not list then list = {}; eventWaits[name] = list end
    list[#list + 1] = w
    return w.id
end

--- Run fn() in its own thread (it may wait: an API call, the database, a player) and continue from
--- the pin it answers, with the outputs table it answers second. An error ends the pulse. If the
--- activation ended first, fn is not started, or its answer goes to opts.late(...) so whatever it
--- made can be put away (a payment it took goes through ctx:receipt, which refunds it by itself).
function CTX:call(fn, opts)
    if type(fn) ~= 'function' then bad('call takes a function') end
    local w = newWait(self, 'call')
    if not w then return nil end
    self.fresh = true
    Ports.thread(function()
        if w.dead then return end
        w.started = true
        local r = table.pack(pcall(fn))
        local inst = w.inst
        if w.dead or inst.status ~= 'on' or w.gen ~= inst.gen then
            kill(w)
            if r[1] and opts and opts.late ~= nil then
                local ok, err = pcall(opts.late, table.unpack(r, 2, r.n))
                if not ok then logTo(inst, 'error', w.node, 'its late handler failed: ' .. tostring(err)) end
            end
            return
        end
        if not r[1] then
            kill(w)
            if isRefusal(r[2]) then endPulse(w.pulse, 'refused', errText(r[2]), w.node)
            else pulseError(w.pulse, w.node, 'it failed: ' .. errText(r[2])) end
            return
        end
        resolve(w, r[2], r[3])
        dropIfOver(w.pulse)
    end)
    return w.id
end

--- Be told once when this activation ends: fn(pin, why).
function CTX:onEnd(fn)
    if not self.token then bad('only a waiting card has an end') end
    if type(fn) ~= 'function' then bad('onEnd takes a function') end
    if self.token.dead then
        Ports.threadNow(function() pcall(fn, nil, 'already ended') end)
        return
    end
    self.token.onEnd = self.token.onEnd or {}
    self.token.onEnd[#self.token.onEnd + 1] = fn
end

--- End the whole pulse here (every branch, every wait): the Stop card. Only from a card's own step.
function CTX:stopPulse()
    if not self.step then bad('Stop works only as a card') end
    self.stopped = true
end

--- End this pulse as CALLED OFF (the Call Off card): REFUSED, so every payment it holds is given back
--- and anything it waits for dies. Not an error.
function CTX:callOff(why)
    if not self.step then bad('Call Off works only as a card') end
    refuse(type(why) == 'string' and why ~= '' and why:sub(1, 120) or 'called off')
end

-- ============================================
-- Running one step
-- ============================================

local function exec(inst, step)
    local pulse = step.pulse
    pulse.pending = pulse.pending - 1
    if pulse.status ~= 'running' then return nil end
    if dropIfOver(pulse) then return nil end
    local node = inst.graph.nodes[step.node]
    local def = node and node.def
    if not def then pulseError(pulse, step.node, 'a wire leads to a card that is not there') return nil end
    if step.depth > L.chain then
        pulseError(pulse, node.id, ('runaway: %d cards in a row without a pause'):format(L.chain))
        return def
    end
    pulse.steps = pulse.steps + 1
    if pulse.steps > L.pulseSteps then
        pulseError(pulse, node.id, ('runaway: %d cards in one pulse'):format(L.pulseSteps))
        return def
    end
    spend(inst, pulse, def.cost)
    inst.steps = inst.steps + 1

    local ctx = setmetatable({ inst = inst, pulse = pulse, node = node, pin = step.pin, depth = step.depth,
                               frame = step.frame, memo = {}, step = true }, CTX)
    if def.kind == 'wait' then
        local key = step.frame.id .. ':' .. node.id
        local cur = pulse.active[key]
        if cur then
            for _, w in ipairs(cur.waits) do
                if w.kind == 'call' and w.started and not w.dead then
                    trace(inst, pulse, node.id, step.pin, 'busy')
                    maybeDone(pulse)
                    return def
                end
            end
            endToken(cur, nil, 'restarted')
        end
        tokSeq = tokSeq + 1
        ctx.token = { key = key, node = node.id, pulse = pulse, waits = {}, seq = tokSeq }
        pulse.active[key] = ctx.token
    end

    trace(inst, pulse, node.id, step.pin, 'enter', step.from, step.fromPin)
    -- IN A TEST NOTHING OF VALUE STAYS (enforced here, at the framework): a card with a power (money,
    -- items, others) runs its dryRun there, which says what it would have done (no money moves), or
    -- hands out items stamped with the test that its end takes back (Give Item, Sell, Drop Item:
    -- server/systems/test_items.lua); one with none is refused, never run for real.
    local run = def.run
    if inst.test and def.power then
        run = def.dryRun or function()
            local words = {}
            for _, p in ipairs(def.powers or { def.power }) do
                words[#words + 1] = p == 'money' and 'move money' or p == 'items' and 'move items'
                    or p == 'make' and 'make things for the server' or 'act on others'
            end
            refuse(('%s cannot be tried in a test yet (it would %s for real)'):format(def.title, table.concat(words, ' and ')))
        end
    end
    local prev = current
    current = { inst = inst, pulse = pulse, depth = step.depth }
    local ok, res, outs = runGuarded(run, ctx)
    current = prev
    if not ok then
        if isRefusal(res) then endPulse(pulse, 'refused', errText(res), node.id)
        else pulseError(pulse, node.id, errText(res)) end
        return def
    end
    if pulse.status ~= 'running' then return def end
    if ctx.stopped then
        endPulse(pulse, 'done', nil, node.id)
        return def
    end
    if ctx.token and not ctx.token.dead and #ctx.token.waits == 0 then endToken(ctx.token, nil, 'no wait') end
    local stored, why = storeOutputs(inst, node, step.frame, outs)
    if not stored then pulseError(pulse, node.id, why) return def end
    if res ~= nil then
        if type(res) == 'string' then res = { res } end
        if type(res) ~= 'table' then pulseError(pulse, node.id, 'answered something that is not a pin') return def end
        for i = 1, #res do
            if not def._outputs[res[i]] then
                pulseError(pulse, node.id, ('answered "%s", which this card does not have'):format(tostring(res[i])))
                return def
            end
        end
        maybeSettle(pulse, def, res)
        for i = 1, #res do trace(inst, pulse, node.id, res[i], 'out') end
        for i = #res, 1, -1 do follow(inst, pulse, node.id, res[i], step.depth + 1, true, step.frame) end
    end
    if dropIfOver(pulse) then return def end
    maybeDone(pulse)
    return def
end

-- ============================================
-- Starting pulses (triggers)
-- ============================================

--- Start a pulse at a trigger card: `values` its value outputs, `context` { player, vehicle }, at
--- `depth` (a pulse a card's own action set off counts from that card). Answers the pulse, or nil
--- and why it was not started (dropped and counted).
local function startPulse(inst, nodeId, values, context, pin, depth)
    if inst.status ~= 'on' then return nil, 'off' end
    if paused(inst) then inst.dropped.paused = inst.dropped.paused + 1 return nil, 'paused' end
    depth = depth or 0
    if depth > L.chain then
        inst.dropped.runaway = inst.dropped.runaway + 1
        logTo(inst, 'error', nodeId, ('runaway: the system keeps setting itself off (%d cards deep)'):format(L.chain))
        noteEnded(inst, true)
        return nil, 'runaway'
    end
    context = context or {}
    local player = context.player and C.coerce('player', context.player) or nil
    if player and player.session == nil and Ports.session then player.session = Ports.session(player.source) end
    -- A Test hears its tester, and what is nobody's (its timers, When Switched On): ctx:source keeps
    -- what those touch to the tester.
    if inst.only and player and player.source ~= inst.only then return nil, 'not the tester' end
    -- ...and the switched-on copy ignores whoever is testing a draft of it.
    if not inst.test and player and testing[inst.key] and testing[inst.key][player.source] then return nil, 'testing' end
    if inst.pulseCount >= L.pulsesPerSystem then inst.dropped.busy = inst.dropped.busy + 1 return nil, 'busy' end
    local src = player and player.source
    if src and (inst.perPlayer[src] or 0) >= L.pulsesPerPlayer then
        inst.dropped.busy = inst.dropped.busy + 1
        return nil, 'busy'
    end
    local node = inst.graph.nodes[nodeId]
    nextPulse = nextPulse + 1
    local now = Ports.now()
    local pulse = {
        id = nextPulse, inst = inst, status = 'running', pending = 0, waits = 0, steps = 0, active = {},
        cancelHooks = {}, receipts = {}, rate = 0, rateAt = now,
        ctx = { player = player, vehicle = context.vehicle and C.coerce('vehicle', context.vehicle) or nil },
        startedAt = now, trigger = nodeId,
    }
    pulse.frame = newFrame(nil)
    inst.pulses[pulse.id] = pulse
    inst.pulseCount = inst.pulseCount + 1
    if src then inst.perPlayer[src] = (inst.perPlayer[src] or 0) + 1 end
    local ok, why = storeOutputs(inst, node, pulse.frame, values)
    if not ok then pulseError(pulse, nodeId, why) return nil, 'error' end
    trace(inst, pulse, nodeId, pin or node.def.outputs[1], 'trigger')
    spend(inst, pulse, node.def.cost)
    if dropIfOver(pulse) then return nil, 'dropped' end
    follow(inst, pulse, nodeId, pin or node.def.outputs[1], depth, false, pulse.frame)
    maybeDone(pulse)
    return pulse
end

--- Let `name` be waited for by cards (ctx:on). Trigger cards need no bridging: their names are
--- their own.
function R.bridge(name) bridged[name] = true end

--- Is any switched-on system listening for `name`? (A watcher that costs something per player, the
--- line watcher, runs only while one is.)
function R.listening(name)
    for _, id in ipairs(order) do
        local inst = instances[id]
        if inst and inst.status == 'on' and inst.graph.triggers[name] then return true end
    end
    return false
end

--- What a hook should say when it tells the systems something: the depth of the step running now
--- (nil when none is). The dispatcher passes it to R.emit, so a system that sets itself off is a
--- loop like any other.
function R.currentDepth() return current and current.depth or nil end

local function triggerFailed(inst, nodeId, err)
    local n = (inst.triggerErrors[nodeId] or 0) + 1
    inst.triggerErrors[nodeId] = n
    if n <= 3 or n % 100 == 0 then
        logTo(inst, 'error', nodeId, ('its trigger check failed (%d times): %s'):format(n, errText(err)))
    end
    noteEnded(inst, true)
end

--- Tell the systems something happened (the dispatcher calls this for each whip hook it hears).
--- Trigger cards listening for `name` start pulses; waiting cards (ctx:on) may carry on. Card code
--- never runs here: it runs in the next pass. `opts.depth`: R.currentDepth() when the hook fired.
---@return number started
function R.emit(name, payload, opts)
    payload = payload == nil and {} or payload
    local depth = opts and tonumber(opts.depth) or (current and current.depth)
    depth = depth and (depth + 1) or 0
    local started = 0
    for _, id in ipairs(order) do
        local inst = instances[id]
        local list = inst and inst.status == 'on' and inst.graph.triggers[name]
        if list then
            for _, nodeId in ipairs(list) do
                if inst.status ~= 'on' then break end
                local node = inst.graph.nodes[nodeId]
                local t = node.def.trigger
                local m = t.match
                local values, context, pin = payload, nil, nil
                local ok = true
                -- A trigger heard many times a second (a car moving) may say quickly, with no card
                -- context, that this one is not for it.
                if t.test then
                    local tok, yes = pcall(t.test, node.props, payload)
                    if not tok or not yes then m, ok, values = nil, false, nil end
                end
                if m then
                    local mctx = setmetatable({ inst = inst, node = node, memo = {}, frame = newFrame(nil) }, CTX)
                    ok, values, context, pin = runGuarded(m, mctx, payload)
                    if not ok then triggerFailed(inst, nodeId, values); values = nil end
                end
                if ok and values ~= nil then
                    if startPulse(inst, nodeId, values, context, pin, depth) then started = started + 1 end
                end
            end
        end
    end
    local waits = eventWaits[name]
    if waits then
        local n = #waits
        for i = 1, n do
            local w = waits[i]
            if not w.dead and w.inst.status == 'on' and w.gen == w.inst.gen and w.pulse.status == 'running' then
                local wctx = setmetatable({ inst = w.inst, pulse = w.pulse, node = w.inst.graph.nodes[w.node],
                                            frame = w.frame, memo = {}, depth = w.depth }, CTX)
                local ok, pin, outs = runGuarded(w.filter, wctx, payload)
                if not ok then
                    local pulse, node = w.pulse, w.node
                    kill(w)
                    if isRefusal(pin) then endPulse(pulse, 'refused', errText(pin), node)
                    else pulseError(pulse, node, 'its event check failed: ' .. errText(pin)) end
                elseif pin ~= nil then
                    local pulse = w.pulse
                    resolve(w, pin, outs)
                    dropIfOver(pulse)
                end
            end
        end
    end
    if started > 0 then wake() end
    return started
end

-- ============================================
-- Switching on and off
-- ============================================

--- Switch a compiled system on (SystemGraph.compile's result).
---@param graph table
---@param opts table  { key, gen, tag, test = bool, only = tester's server id, echo = bool,
---                     vars = { [scopeKey] = { [name] = value } } (remembered values), onTrace, watchValues }
---@return table inst
function R.start(graph, opts)
    opts = opts or {}
    nextInst = nextInst + 1
    local win = {}
    for i = 1, L.errorWindowSec do win[i] = { sec = nil, ended = 0, errors = 0 } end
    -- What it remembers, checked against its variables one by one, never as one capped copy of the
    -- whole (one oversized value would wipe them all).
    local vars = {}
    for scopeKey, store in pairs(type(opts.vars) == 'table' and opts.vars or {}) do
        if type(scopeKey) == 'string' and type(store) == 'table' then
            for name, v in pairs(store) do
                local decl = graph.vars[name]
                local got = decl and C.coerce(decl.type, v, nil)
                if got ~= nil then
                    local s = vars[scopeKey]
                    if not s then s = {}; vars[scopeKey] = s end
                    s[name] = got
                end
            end
        end
    end
    local inst = {
        id = nextInst, key = opts.key or ('system' .. nextInst), gen = opts.gen or 1, tag = opts.tag,
        graph = graph, status = 'on', test = opts.test == true, only = opts.only, echo = opts.echo == true,
        vars = vars, state = {}, pulses = {}, pulseCount = 0, perPlayer = {}, liveWaits = 0,
        q = newDeque(), budget = { at = Ports.now(), used = 0 }, playerBudget = {},
        win = win, errors = 0, dropped = { budget = 0, busy = 0, paused = 0, runaway = 0 }, triggerErrors = {},
        pauses = 0, steps = 0, startedAt = Ports.now(),
        trace = { n = 0 }, log = { n = 0 }, onTrace = opts.onTrace, watchValues = opts.watchValues == true,
        lastValues = {}, timers = {}, meta = copy(opts.meta) or {},
        watchState = {},   -- [nodeId] = { [scope] = a Watch card's last reading }
    }
    instances[inst.id] = inst
    order[#order + 1] = inst.id
    if inst.test and inst.only then
        local t = testing[inst.key]
        if not t then t = {}; testing[inst.key] = t end
        local mine = t[inst.only]
        if not mine then mine = { n = 0, from = nextPulse }; t[inst.only] = mine end
        mine.n = mine.n + 1
    end
    -- Trigger timers ("Every 5 seconds"): one persistent wait each, in the heap.
    for _, nodeId in ipairs(graph.timers) do
        local node = graph.nodes[nodeId]
        local ok, ms = pcall(node.def.timer, C.withDefaults(node.def, node.props))
        ms = ok and tonumber(ms) or nil
        if ms and ms == ms then
            nextWait = nextWait + 1
            local every = math.max(ms, L.minTimerMs)
            local w = { id = nextWait, inst = inst, gen = inst.gen, node = nodeId, kind = 'trigger',
                        every = every, at = Ports.now() + every, perPlayer = node.def.perPlayer == true }
            inst.timers[#inst.timers + 1] = w
            heapPush(w)
        else
            logTo(inst, 'error', nodeId, 'its timer could not be read')
        end
    end
    -- Watches ("When a Number Goes Above or Below"): one persistent wait each, like a timer; each turn
    -- checks every scope (watchOnce, below).
    for _, nodeId in ipairs(graph.watches or {}) do
        local node = graph.nodes[nodeId]
        local props = C.withDefaults(node.def, node.props)
        local wdef = node.def.watch
        local ok, ms = pcall(wdef.every, props)
        local okP, per = true, false
        if wdef.perPlayer then okP, per = pcall(wdef.perPlayer, props) end
        ms = ok and tonumber(ms) or nil
        if ms and ms == ms and okP then
            nextWait = nextWait + 1
            local every = math.max(ms, L.minTimerMs)
            local w = { id = nextWait, inst = inst, gen = inst.gen, node = nodeId, kind = 'watch', every = every,
                        at = Ports.now() + every, perPlayer = per == true, cursor = 1 }
            inst.timers[#inst.timers + 1] = w
            heapPush(w)
        else
            logTo(inst, 'error', nodeId, 'how often it checks could not be read')
        end
    end
    logTo(inst, 'info', nil, ('switched on (generation %s)%s'):format(tostring(inst.gen), inst.test and ' as a test' or ''))
    for _, nodeId in ipairs(graph.onStart) do startPulse(inst, nodeId, {}, {}) end
    wake()
    return inst
end

--- Switch an instance off: 'off' or 'faulted'. Every pulse going is CANCELLED (its receipts are
--- refunded, its cancel hooks run), every wait dies, and Ports.onStop releases what it made.
stopInstance = function(inst, outcome, why)
    if inst.status ~= 'on' then return false end
    inst.status = outcome or 'off'
    inst.reason = why
    inst.stoppedAt = Ports.now()
    local ps = {}
    for _, p in pairs(inst.pulses) do ps[#ps + 1] = p end
    table.sort(ps, function(a, b) return a.id < b.id end)
    for _, p in ipairs(ps) do endPulse(p, 'cancelled', why or 'the system was switched off') end
    for _, w in ipairs(inst.timers) do w.dead = true end
    inst.q = newDeque()
    instances[inst.id] = nil
    dirtyEvents = true
    local t = inst.test and inst.only and testing[inst.key]
    if t and t[inst.only] then
        local mine = t[inst.only]
        mine.n = mine.n - 1
        if mine.n <= 0 then t[inst.only] = nil end
        if next(t) == nil then testing[inst.key] = nil end
    end
    logTo(inst, outcome == 'faulted' and 'error' or 'info', nil,
        ('%s%s'):format(outcome == 'faulted' and 'FAULTED' or 'switched off', why and (': ' .. tostring(why)) or ''))
    if Ports.onStop then
        Ports.threadNow(function()
            local ok, err = pcall(Ports.onStop, inst, outcome, why)
            if not ok then Ports.log(('%s: its stop hook failed: %s'):format(inst.key, tostring(err))) end
        end)
    end
    return true
end

---@return boolean stopped
function R.stop(instId, why) local inst = instances[instId]; return inst ~= nil and stopInstance(inst, 'off', why) end
function R.fault(instId, why) local inst = instances[instId]; return inst ~= nil and stopInstance(inst, 'faulted', why) end
function R.stopAll(why)
    local ids = {}
    for id in pairs(instances) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do R.stop(id, why) end
end

---@return table|nil inst
function R.get(instId) return instances[instId] end

--- A line in an instance's log from outside a card (what its standing things said).
function R.note(inst, level, nodeId, msg)
    if type(inst) == 'table' and inst.log then logTo(inst, level or 'info', nodeId, tostring(msg)) end
end
function R.list()
    local out = {}
    for _, id in ipairs(order) do if instances[id] then out[#out + 1] = instances[id] end end
    return out
end

--- A player is gone (logout, drop). Handled at the start of the next pass, never inside a card's
--- step (a pulse must not cancel itself by what it did): their pulses are cancelled in
--- every system (receipts refunded), and their per-player VARIABLES forgotten (a remembered one lives
--- on through Ports.remember). Cards' own memory per player is the character's and stays.
---
--- Only the pulses ALREADY GOING when it was said are cancelled: one started after it
--- (When a Player Leaves, told of the leave) runs, and acts on nobody gone (ctx:source refuses them).
--- A pulse whose own card said it is never cancelled by it.
function R.playerGone(src, charId)
    gone[#gone + 1] = { kind = 'player', src = src, charId = charId, upTo = nextPulse, except = current and current.pulse }
    wake()
end

--- A car is gone for good (deleted, released): its pulses are cancelled, what is kept per car
--- forgotten. Handled at the start of the next pass, like a player; an impound that deleted the car
--- carries on.
function R.vehicleGone(vehicleId)
    gone[#gone + 1] = { kind = 'vehicle', id = vehicleId, upTo = nextPulse, except = current and current.pulse }
    wake()
end

local function handleGone()
    if #gone == 0 then return end
    local list = gone
    gone = {}
    for _, g in ipairs(list) do
        for _, id in ipairs(order) do
            local inst = instances[id]
            if inst then
                local ps = {}
                for _, p in pairs(inst.pulses) do
                    local about = (g.kind == 'player' and playerOf(p) == g.src) or (g.kind == 'vehicle' and p.ctx.vehicle == g.id)
                    if about and p.id <= g.upTo and p ~= g.except then ps[#ps + 1] = p end
                end
                table.sort(ps, function(a, b) return a.id < b.id end)
                for _, p in ipairs(ps) do
                    endPulse(p, 'cancelled', g.kind == 'player' and 'their player left' or 'its car is gone')
                end
                if g.kind == 'player' then
                    inst.playerBudget[g.src] = nil
                    -- Their Watch readings go: back, their first reading is no change.
                    local prefix = tostring(g.src) .. ':'
                    for _, states in pairs(inst.watchState) do
                        for k in pairs(states) do if k:sub(1, #prefix) == prefix then states[k] = nil end end
                    end
                    -- Their per-player variables go, but a REMEMBERED one stays: it is theirs when they
                    -- come back (and is saved through Ports.remember all along).
                    local key = g.charId ~= nil and ('p:' .. idKey(g.charId)) or nil
                    local store = key and inst.vars[key]
                    if key and store then
                        for name in pairs(store) do
                            local decl = inst.graph.vars[name]
                            if not (decl and decl.remember) then store[name] = nil end
                        end
                        if next(store) == nil then inst.vars[key] = nil end
                    end
                else
                    local key = 'v:' .. idKey(g.id)
                    inst.vars[key] = nil
                    for _, byNode in pairs(inst.state) do byNode[key] = nil end
                end
            end
        end
    end
end

--- What an instance has done (the hub, the editor's Test): counts, its log and trace, oldest first.
function R.report(inst)
    local function ring(t, size)
        local out = {}
        for i = math.max(1, t.n - size + 1), t.n do out[#out + 1] = t[((i - 1) % size) + 1] end
        return out
    end
    local ended, errors = windowTotals(inst)
    -- Each pin's value is its own bounded copy already (noteValue): handed over card by card, never
    -- one copy of the whole (which gave up past 512 entries, and every value was lost).
    local values
    if inst.watchValues then
        values = {}
        for nodeId, pins in pairs(inst.lastValues) do
            local t = {}
            for k, v in pairs(pins) do t[k] = v end
            values[nodeId] = t
        end
    end
    return {
        key = inst.key, gen = inst.gen, status = inst.status, reason = inst.reason, test = inst.test,
        pulses = inst.pulseCount, steps = inst.steps, pauses = inst.pauses, paused = paused(inst),
        dropped = copy(inst.dropped), lastMinute = { ended = ended, errors = errors },
        log = ring(inst.log, L.log), trace = ring(inst.trace, L.trace),
        values = values,
    }
end

-- ============================================
-- Watches
-- ============================================
--
-- A WATCH card is a trigger checked again and again ("When a Number Goes Above or Below": a car's
-- speed past a limit). Each check works its value inputs out NOW, in a frame of its own holding the
-- card's own outputs (the player it checks for), so Their Car(Player) can feed its Number. The card's
-- check compares the reading with the last one for that scope (each player, or the whole server) and
-- says whether a pulse starts: once per crossing, never on every check. A check costs points like a
-- step (it is charged to that player's share); over budget, or with no reading (on foot: no car speed),
-- it starts nothing and the next reading is no change. A Test checks only its tester; the switched-on
-- copy leaves its tester out.

local function watchOnce(inst, w, p)
    if inst.only and p and p.source ~= inst.only then return end
    if not inst.test and p and testing[inst.key] and testing[inst.key][p.source] then return end
    local node = inst.graph.nodes[w.node]
    local def = node.def
    -- Not a pulse: what a pulse is to the cards that work the inputs out (whose player, whose budget).
    local probe = { id = nextPulse + 1, inst = inst, status = 'running', ctx = { player = p }, receipts = {}, probe = true }
    local frame = newFrame(nil)
    frame.out[node.id] = p and { player = p } or {}
    local ctx = setmetatable({ inst = inst, pulse = probe, node = node, frame = frame, memo = {}, depth = 0 }, CTX)
    spend(inst, probe, def.cost)
    if probe.over then return end
    local states = inst.watchState[node.id]
    if not states then states = {}; inst.watchState[node.id] = states end
    local key = p and (tostring(p.source) .. ':' .. tostring(p.session)) or 'e'
    local ok, reading, outs = runGuarded(def.watch.check, ctx, states[key])
    if probe.over then return end
    if not ok then
        -- A missing value is no reading (refused); anything else is the card broken, said as a trigger's.
        if not isRefusal(reading) then triggerFailed(inst, node.id, reading) end
        states[key] = nil
        return
    end
    states[key] = reading
    if outs ~= nil and inst.status == 'on' then
        if type(outs) ~= 'table' then outs = {} end
        if p then outs.player = p end
        startPulse(inst, node.id, outs, { player = p })
    end
end

--- One turn of a Watch's wait: every scope it checks. A big server's players are checked a slice a
--- pass (the pass's 2 ms), the rest the next pass, never one long pass.
local function watchTurn(inst, w, now, t0)
    if paused(inst) then
        w.at = now + w.every
        return
    end
    if not w.perPlayer then
        watchOnce(inst, w, nil)
        w.at = now + w.every
        return
    end
    local ok, list = pcall(Ports.players or function() return {} end)
    list = ok and type(list) == 'table' and list or {}
    local i = w.cursor or 1
    while i <= #list and inst.status == 'on' do
        watchOnce(inst, w, list[i])
        i = i + 1
        if i % 25 == 0 and (Ports.clock() - t0) * 1000 >= L.passMs then break end
    end
    if i <= #list and inst.status == 'on' then
        w.cursor = i
        w.at = now + 1   -- the rest next pass
    else
        w.cursor = 1
        w.at = now + w.every
    end
end

-- ============================================
-- The pass
-- ============================================

local function passInner()
    handleGone()
    local now = Ports.now()
    local t0 = Ports.clock()
    local timersRun = 0
    while heap[1] and heap[1].at <= now and timersRun < L.timersPerPass do
        local w = heapPop()
        if not w.dead then
            timersRun = timersRun + 1
            local inst = w.inst
            if inst.status ~= 'on' or w.gen ~= inst.gen then
                w.dead = true
            elseif w.kind == 'trigger' then
                if w.perPlayer then
                    -- One pulse for each player, each with that player: "every 5 s, for each player"
                    -- (per-player variables work in it; a For Each over a list has no player of its own).
                    local ok, list = pcall(Ports.players or function() return {} end)
                    for _, p in ipairs(ok and type(list) == 'table' and list or {}) do
                        if inst.status ~= 'on' then break end
                        startPulse(inst, w.node, { player = p }, { player = p })
                    end
                else
                    startPulse(inst, w.node, {}, {})
                end
                w.at = now + w.every
                heapPush(w)
            elseif w.kind == 'watch' then
                watchTurn(inst, w, now, t0)
                if inst.status == 'on' then heapPush(w) end
            elseif w.poll then
                if paused(inst) then
                    w.at = inst.pausedUntil
                    heapPush(w)
                else
                    local pulse = w.pulse
                    spend(inst, pulse, 1)
                    if not dropIfOver(pulse) then
                        local node = inst.graph.nodes[w.node]
                        local pctx = setmetatable({ inst = inst, pulse = pulse, node = node, frame = w.frame, memo = {},
                                                    depth = w.depth }, CTX)
                        local ok, pin, outs = runGuarded(w.poll, pctx)
                        if not ok then
                            kill(w)
                            if isRefusal(pin) then endPulse(pulse, 'refused', errText(pin), node.id)
                            else pulseError(pulse, node.id, 'its check failed: ' .. errText(pin)) end
                        elseif pin ~= nil then
                            resolve(w, pin, outs)
                            dropIfOver(pulse)
                        else
                            w.at = now + w.every
                            heapPush(w)
                        end
                    end
                end
            else
                resolve(w, w.pin)
            end
        end
        if timersRun % 50 == 0 and (Ports.clock() - t0) * 1000 >= L.passMs then break end
    end

    local total = 0
    local n = #order
    local out = false
    for k = 1, n do
        local inst = instances[order[((rr + k - 1) % n) + 1]]
        if inst and not paused(inst) then
            local steps = 0
            while steps < L.perInstance and total < L.perPass do
                local step = popFront(inst.q)
                if not step then break end
                local def = exec(inst, step)
                steps, total = steps + 1, total + 1
                if (total % 50 == 0 or (def and def.heavy)) and (Ports.clock() - t0) * 1000 >= L.passMs then out = true break end
                if inst.status ~= 'on' or paused(inst) then break end
            end
        end
        if out or total >= L.perPass then break end
    end
    rr = rr + 1

    -- Pulses past their life (an hour by default) are cancelled; checked about once a second.
    for _, id in ipairs(order) do
        local inst = instances[id]
        if inst and now - (inst.agedAt or 0) >= 1000 then
            inst.agedAt = now
            local old = {}
            for _, p in pairs(inst.pulses) do if now - p.startedAt > L.pulseLifeMs then old[#old + 1] = p end end
            table.sort(old, function(a, b) return a.id < b.id end)
            for _, p in ipairs(old) do endPulse(p, 'cancelled', 'it ran for more than an hour') end
        end
    end

    local live = {}
    for _, id in ipairs(order) do if instances[id] then live[#live + 1] = id end end
    order = live
    if dirtyEvents then
        for ename, list in pairs(eventWaits) do
            local keep = {}
            for _, w in ipairs(list) do if not w.dead then keep[#keep + 1] = w end end
            eventWaits[ename] = #keep > 0 and keep or nil
        end
        dirtyEvents = false
    end
    if #heap > 64 then
        local dead = 0
        for _, w in ipairs(heap) do if w.dead then dead = dead + 1 end end
        if dead * 2 > #heap then
            local keep = {}
            for _, w in ipairs(heap) do if not w.dead then keep[#keep + 1] = w end end
            heap = {}
            for _, w in ipairs(keep) do heapPush(w) end
        end
    end

    if #order == 0 then heap = {} return R.SLEEP_MS end
    if #gone > 0 or (heap[1] and heap[1].at <= Ports.now()) then return 0 end
    for _, id in ipairs(order) do
        local inst = instances[id]
        if not dequeEmpty(inst.q) and not paused(inst) then return 0 end
    end
    while heap[1] and heap[1].dead do heapPop() end
    local soonest = R.IDLE_MS
    if heap[1] then soonest = math.min(soonest, math.max(R.MIN_MS, math.ceil(heap[1].at - Ports.now()))) end
    for _, id in ipairs(order) do
        local inst = instances[id]
        if inst.pausedUntil and not dequeEmpty(inst.q) then
            soonest = math.min(soonest, math.max(R.MIN_MS, math.ceil(inst.pausedUntil - Ports.now())))
        end
    end
    return math.tointeger(soonest) or math.floor(soonest)
end

--- One scheduler pass. Answers how long to sleep before the next: 0 when work is queued, otherwise a
--- whole number of ms (at least MIN_MS).
function R.pass()
    passing, wakeAsked = true, false
    local ok, res = pcall(passInner)
    passing = false
    current = nil
    if not ok then error(res, 0) end
    return res
end

--- How many waits are held (the harness checks a switched-off system leaves none behind).
function R._counts()
    local events, live, open = 0, 0, 0
    for _, list in pairs(eventWaits) do events = events + #list end
    for _, w in ipairs(heap) do if not w.dead then live = live + 1 end end
    for _ in pairs(receipts) do open = open + 1 end
    return { timers = #heap, liveTimers = live, events = events, receipts = open }
end

--- Forget everything (the harness).
function R._reset()
    instances, order, rr, heap, eventWaits, dirtyEvents, receipts, gone = {}, {}, 0, {}, {}, false, {}, {}
    nextInst, nextPulse, nextFrame, nextWait, nextReceipt, tokSeq = 0, 0, 0, 0, 0, 0
    passing, wakeAsked, current = false, false, nil
    server = { at = 0, used = 0 }
    bridged = {}
    testing = {}
end

--- Is this player testing a draft of this system now? (The hub: one test at a time per builder.)
function R.isTesting(key, src) return testing[key] ~= nil and testing[key][src] ~= nil end
