-- ============================================
-- Systems — the editor's server half: the hub, saving, checking, testing
-- ============================================
--
-- What the /systems screen asks for (client/systems_editor.lua forwards each request here). The
-- Systems Creator's OWN callbacks and upload, never the Director's (a director.build holder must not
-- edit a system that moves money). Each answers `result` or `false, why`.
--
-- Who may: a systems BUILDER (systems.build) sees every system, makes, edits, checks and
-- tests; a systems ADMIN (systems.admin) also switches them on and off, approves what a revision may
-- do (money, items), and deletes. The gate is each callback's `permission`, never a check in a handler.
--
--   whip_core:systems:list        the hub: every system, on or off and why, who has it open, tests
--   whip_core:systems:cards       the card types (SystemCards.wire) and the value types
--   whip_core:systems:open        one system's document (its draft, or a revision)
--   whip_core:systems:watch       the editor back on a system it had open (after a close)
--   whip_core:systems:history     its revisions
--   whip_core:systems:create      a new system: empty, from an example, or a copy of another
--   whip_core:systems:save        the draft, revision-checked (SystemStore.save)
--   whip_core:systems:check       an unsaved document, checked (SystemGraph.check)
--   whip_core:systems:activate    switch a revision on (admin); :deactivate off; :approve its powers;
--                                 :delete (admin, and it must be off)
--   whip_core:systems:test        a Test: the editor's document, switched on for the asker alone
--                                 (walk.lua: the live copy ignores them meanwhile, nothing of value
--                                 moves); :testReport what it has done so far; :testStop ends it
--
-- A document goes up as a latent event (a big plain event never arrives): whip_core:server:systemsDoc
-- with a token, then the callback names the token. Up to three uploads wait per player, by token, so
-- a quiet Check never takes the upload a Save is waiting for.

local CORE = GetCurrentResourceName()
local SB, SA = 'systems.build', 'systems.admin'
local R = SystemsRuntime
local C = SystemCards

local UPLOAD_WAIT_MS = 6000        -- with the save's own database time, under the client's 10 s callback timeout
local UPLOAD_KEEP_MS = 15000       -- an upload nobody asked for is forgotten after this
local UPLOADS_KEPT = 3             -- per player
local UPLOAD_BPS = 500000          -- what the client is told to send at (bytes a second)
local EXAMPLES = { 'speedcam', 'carwash' }   -- server/systems/examples/<name>.json offered by New (and /systems load)
local TEST_MAX_MS = 30 * 60 * 1000 -- a test nobody stops ends by itself
local STEP_EVERY_MS = 250          -- what ran is sent at most this often
local PULSE_MAX = 40               -- the newest this many steps a batch

local uploads = {}   -- [src] = { [token] = { doc, why, at } }
local editing = {}   -- [key] = { [src] = name }
local endTest        -- (Test, below: delete ends a deleted system's tests)

local function say(fmt, ...) print(('[whip_core:systems] ' .. fmt):format(...)) end

-- ============================================
-- A document from a page: plain data only
-- ============================================
--
-- Whatever a client sent, so it is copied, never kept: text, numbers, yes/no and tables of those, keys
-- that are words or list positions, bounded. What it MEANS is SystemGraph.check's job.

local MAX_DEPTH, MAX_ENTRIES = 12, 60000

local function isFuncRef(v)
    if rawget(v, '__cfx_functionReference') ~= nil then return true end
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

local function copyPlain(v, depth, count)
    local t = type(v)
    if t == 'string' or t == 'boolean' then return v end
    if t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return nil, 'a number in it is not a number' end
        return v
    end
    if t ~= 'table' then return nil, 'it holds something that is not text, a number or a list' end
    if isFuncRef(v) then return nil, 'a function is not a value' end
    if depth > MAX_DEPTH then return nil, 'it is nested too deep' end
    local out = {}
    local k, x = next(v)
    while k ~= nil do
        count[1] = count[1] + 1
        if count[1] > MAX_ENTRIES then return nil, 'it is too big' end
        if type(k) ~= 'string' and math.type(k) ~= 'integer' then return nil, 'it has a key that is not a word' end
        if type(k) == 'string' and #k > 64 then return nil, 'it has a key that is too long' end
        local c, why = copyPlain(x, depth + 1, count)
        if why then return nil, why end
        out[k] = c
        k, x = next(v, k)
    end
    return out
end

SecureEvent('whip_core:server:systemsDoc', {
    permission = SB,
    whileDead = true,
    rateLimit = 300,
    burst = 4,
    params = { { 'token', 'id' }, { 'doc', 'any' } },
}, function(source, _, token, doc)
    local clean, why = copyPlain(doc, 1, { 0 })
    if clean and (clean.format ~= 1 or clean.kind ~= 'system') then clean, why = nil, 'that is not a system document' end
    local mine = uploads[source]
    if not mine then mine = {}; uploads[source] = mine end
    local now = GetGameTimer()
    -- The oldest goes when a fourth arrives: a page only ever waits on its newest few. Oldest by when it
    -- landed, then by its token (a page counts them up), so two in one moment go in the order they came.
    local n, oldest, oldestAt = 0, nil, math.huge
    for tok, u in pairs(mine) do
        if now - u.at > UPLOAD_KEEP_MS then mine[tok] = nil
        else
            n = n + 1
            if u.at < oldestAt or (u.at == oldestAt and tok < oldest) then oldest, oldestAt = tok, u.at end
        end
    end
    if n >= UPLOADS_KEPT and oldest then mine[oldest] = nil end
    mine[token] = { doc = clean, why = why, at = now }
end)

--- The document a page sent with `token`, once it has landed. Answers the doc, or nil and why. WAITS.
local function takeUpload(src, token)
    local deadline = GetGameTimer() + UPLOAD_WAIT_MS
    while true do
        local mine = uploads[src]
        local u = mine and mine[token]
        if u then
            mine[token] = nil
            if not u.doc then return nil, 'That system could not be read: ' .. tostring(u.why) end
            return u.doc
        end
        if GetGameTimer() > deadline then return nil, 'The system did not arrive in time: try again' end
        Wait(100)
    end
end

-- ============================================
-- Reading
-- ============================================

local function off()
    if Systems.off then return 'The Systems Creator is off: ' .. Systems.off end
    if not SystemStore.ready then return 'The Systems Creator is still starting' end
    return nil
end

local function editorsOf(key, except)
    local names = {}
    for src, name in pairs(editing[key] or {}) do
        if src ~= except and Players[src] then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

local function markEditing(src, key, name)
    for k, list in pairs(editing) do
        list[src] = nil
        if next(list) == nil then editing[k] = nil end
    end
    if key then
        editing[key] = editing[key] or {}
        editing[key][src] = name
    end
end

--- One of the screen's requests: a builder's unless `level` says SA. `level = false`: no permission,
--- for a request that only ends what the sender owns (their own test), which a builder who has just
--- lost access must still be able to end.
local function cb(name, params, handler, rate, level)
    ---@type string|nil
    local permission = SB
    if level == false then permission = nil elseif level ~= nil then permission = level end
    SecureCallback('whip_core:systems:' .. name, {
        permission = permission,
        whileDead = true,
        rateLimit = rate or 200,
        burst = 5,
        params = params,
    }, handler)
end

--- Two power lists ('items,money') as one, sorted, no repeats.
local function powersUnion(a, b)
    local set, list = {}, {}
    for _, s in ipairs({ a or '', b or '' }) do for p in tostring(s):gmatch('[^,]+') do set[p] = true end end
    for p in pairs(set) do list[#list + 1] = p end
    table.sort(list)
    return table.concat(list, ',')
end

--- A power list in words, for the console and a refusal: 'move money and act on others or the server'.
local POWER_WORDS = { money = 'move money', items = 'move items', others = 'act on others or the server',
                      make = 'make things of its own' }
local function powerWords(list)
    local out = {}
    for p in tostring(list or ''):gmatch('[^,]+') do out[#out + 1] = POWER_WORDS[p] or p end
    if #out == 0 then return 'do nothing of value' end
    return table.concat(out, ' and ')
end

local function powersCovered(needed, approved)
    if needed == '' then return true end
    local ok = {}
    for p in tostring(approved or ''):gmatch('[^,]+') do ok[p] = true end
    for p in needed:gmatch('[^,]+') do if not ok[p] then return false end end
    return true
end

cb('list', {}, function(source)
    local rows = {}
    for _, s in ipairs(SystemStore.ready and SystemStore.list() or {}) do
        local live = Systems.active[s.key]
        s.on = live ~= nil
        s.onRev = live and live.rev or nil
        if live then
            local rep = R.report(live.inst)
            s.pulses, s.errors, s.paused = rep.pulses, rep.lastMinute.errors, rep.paused
            s.dropped = rep.dropped.busy + rep.dropped.budget + rep.dropped.paused + rep.dropped.runaway
        end
        s.editors = editorsOf(s.key, source)
        local testers = {}
        for src, t in pairs(Systems.tests) do
            if t.key == s.key and Players[src] then testers[#testers + 1] = Players[src].fullName end
        end
        table.sort(testers)
        s.testers = testers
        rows[#rows + 1] = s
    end
    return { off = off(), systems = rows, examples = EXAMPLES, admin = Permissions.has(source, SA),
             testing = Systems.tests[source] and Systems.tests[source].key or nil }
end)

cb('cards', {}, function()
    -- The server lane's cards; the value types and their colours.
    local cards = {}
    for _, d in ipairs(C.wire()) do
        if d.side == 'server' or d.side == 'both' then cards[#cards + 1] = d end
    end
    return { cards = cards, types = C.TYPES, format = 1 }
end)

--- What the editor draws from a document: Check's problems, the pins the server works out, and its
--- powers (as its cards say now, and as an admin approved them for `rev`).
local function checked(doc)
    local ok, problems, extra = SystemGraph.check(doc, 'server')
    return ok, problems, extra.pins, extra.powers
end

cb('open', { { 'key', 'key', 64 }, { 'rev', 'int', 0, 1000000000, 0 } }, function(source, player, key, rev)
    local why = off()
    if why then return false, why end
    local row = SystemStore.get(key)
    if not row then return false, 'No system called ' .. key end
    local doc, r, savedPowers, approvedPowers = SystemStore.revision(key, rev > 0 and rev or row.draftRev)
    if not doc then return false, r end
    local _, problems, pins, powers = checked(doc)
    -- Only the draft is being edited: opening an old revision to look at it is not. AFTER THE WAIT,
    -- ASKED AGAIN: still this player's session (a logout meanwhile already forgot them).
    local still = Players[source] and Players[source].session == player.session
    if r == row.draftRev and still then markEditing(source, key, player.fullName) end
    local live = Systems.active[key]
    local needed = powersUnion(savedPowers, powers)
    return { system = row, doc = doc, rev = r, problems = problems, pins = pins, powers = needed,
             approved = approvedPowers, approvedOk = powersCovered(needed, approvedPowers),
             editors = editorsOf(key, source), on = live ~= nil, onRev = live and live.rev or nil,
             uploadBps = UPLOAD_BPS, admin = Permissions.has(source, SA) }
end)

cb('watch', { { 'key', 'key', 64 }, { 'rev', 'int', 0, 1000000000, 0 } }, function(source, player, key, rev)
    local row = SystemStore.get(key)
    if not row then return false, 'No system called ' .. key end
    if rev == row.draftRev then markEditing(source, key, player.fullName) end
    return { editors = editorsOf(key, source) }
end)

cb('history', { { 'key', 'key', 64 } }, function(_, _, key)
    local list, why = SystemStore.history(key, 30)
    if not list then return false, why end
    return { revisions = list }
end)

-- ============================================
-- Writing
-- ============================================

--- A brand-new system's document: one trigger, nothing else yet.
local function emptyDoc(name)
    return {
        format = 1, kind = 'system', name = name, description = '', settings = {}, vars = {},
        nodes = { { id = 'every1', type = 'when.every', v = 1, x = 0, y = 0, props = { seconds = 5 }, values = {} } },
        links = {},
    }
end

local function exampleDoc(name)
    local raw = LoadResourceFile(CORE, ('server/systems/examples/%s.json'):format(name))
    if not raw then return nil, 'No example called ' .. name end
    local ok, doc = pcall(json.decode, raw)
    if not ok or type(doc) ~= 'table' then return nil, 'That example is not readable' end
    -- A file's "spot:<name>" places mean "place me": left empty, for the Places tab.
    for _, n in ipairs(type(doc.nodes) == 'table' and doc.nodes or {}) do
        for k, v in pairs(type(n.props) == 'table' and n.props or {}) do
            if type(v) == 'string' and v:match('^spot:') then n.props[k] = nil end
        end
    end
    return doc
end

cb('create', { { 'key', 'key', 64 }, { 'name', 'string', 80 }, { 'from', 'string', 80, '' } },
function(source, _, key, name, from)
    local why = off()
    if why then return false, why end
    local doc, dwhy
    if from == '' then
        doc = emptyDoc(name)
    elseif from:sub(1, 8) == 'example:' then
        local ex = from:sub(9)
        local known = false
        for _, e in ipairs(EXAMPLES) do if e == ex then known = true end end
        if not known then return false, 'No example called ' .. ex end
        doc, dwhy = exampleDoc(ex)
    elseif from:sub(1, 5) == 'copy:' then
        local other = from:sub(6)
        if not SystemStore.get(other) then return false, 'No system called ' .. other end
        doc, dwhy = SystemStore.revision(other)
    else
        return false, 'Start from nothing, an example or a copy'
    end
    if not doc then return false, dwhy end
    doc.name = name
    local row, cwhy = SystemStore.create(key, name, doc, source)
    if not row then return false, cwhy end
    return { system = row }
end, 1000)

cb('save', { { 'key', 'key', 64 }, { 'baseRev', 'int', 0, 1000000000 }, { 'token', 'id' }, { 'note', 'string', 200, '' } },
function(source, _, key, baseRev, token, note)
    local why = off()
    if why then return false, why end
    local doc, uwhy = takeUpload(source, token)
    if not doc then return false, uwhy end
    local rev, swhy = SystemStore.save(key, baseRev, doc, source, note ~= '' and note or nil)
    if not rev then return false, swhy end
    local _, problems, pins, powers = checked(doc)
    return { rev = rev, problems = problems, pins = pins, powers = powers, approvedOk = powers == '' }
end, 500)

cb('check', { { 'token', 'id' } }, function(source, _, token)
    local doc, uwhy = takeUpload(source, token)
    if not doc then return false, uwhy end
    local ok, problems, pins, powers = checked(doc)
    return { ok = ok, problems = problems, pins = pins, powers = powers }
end, 300)

-- Switching on and off, approving, deleting: admins.

cb('approve', { { 'key', 'key', 64 }, { 'rev', 'int', 1, 1000000000 }, { 'powers', 'string', 60, '' } },
function(source, player, key, rev, seen)
    local why = off()
    if why then return false, why end
    local row = SystemStore.get(key)
    if not row then return false, 'No system called ' .. key end
    local doc, r, savedPowers = SystemStore.revision(key, rev)
    if not doc then return false, r end
    -- What it may do as saved AND as its cards say now (switchOn asks both), and only what the admin
    -- was shown: a list that changed since is refused, never approved unseen.
    local needed = powersUnion(savedPowers, SystemStore.powersOf(doc))
    if needed ~= powersUnion(seen, '') then
        return false, ('Revision %d may %s now: look again before approving'):format(r, powerWords(needed))
    end
    local ok, awhy = SystemStore.approve(key, r, needed, source)
    if not ok then return false, awhy end
    say('%s approved revision %d of %s to %s', tostring(player.fullName), r, key, powerWords(needed))
    return { ok = true, approved = needed }
end, 1000, SA)

cb('activate', { { 'key', 'key', 64 }, { 'rev', 'int', 0, 1000000000, 0 } }, function(source, _, key, rev)
    local why = off()
    if why then return false, why end
    local row = SystemStore.get(key)
    if not row then return false, 'No system called ' .. key end
    rev = rev > 0 and rev or row.draftRev
    local doc, r, savedPowers, approvedPowers = SystemStore.revision(key, rev)
    if not doc then return false, r end
    local needed = powersUnion(savedPowers, SystemStore.powersOf(doc))
    if not powersCovered(needed, approvedPowers) then
        return { ok = false, needsApproval = needed, rev = r }
    end
    local ok, owhy = Systems.switchOn(key, r, source)
    if not ok then return false, owhy end
    return { ok = true, rev = r }
end, 1000, SA)

cb('deactivate', { { 'key', 'key', 64 } }, function(source, player, key)
    local ok, why = Systems.switchOff(key, 'switched off by ' .. tostring(player.fullName), source)
    if not ok then return false, why end
    return { ok = true }
end, 1000, SA)

cb('delete', { { 'key', 'key', 64 } }, function(source, player, key)
    local why = off()
    if why then return false, why end
    if Systems.active[key] then return false, 'It is on: switch it off first' end
    local ok, dwhy = SystemStore.delete(key, source)
    if not ok then return false, dwhy end
    editing[key] = nil
    -- After the wait, asked again: switched on by someone meanwhile, it goes too (nothing may run that no
    -- list shows); and tests of it end, their testers told.
    if Systems.active[key] then Systems.switchOff(key, 'deleted', source) end
    for src, t in pairs(Systems.tests) do
        if t.key == key then
            endTest(src, 'the system was deleted')
            TriggerClientEvent('whip_core:client:systemsTestEnded', src, { outcome = 'off', reason = 'the system was deleted' })
        end
    end
    say('%s deleted %s', tostring(player.fullName), key)
    return { ok = true }
end, 1000, SA)

-- ============================================
-- Test
-- ============================================
--
-- The editor's document as it is now (saved or not), switched on for the tester ALONE, beside the live
-- copy if there is one. The walker keeps them apart (walk.lua's `testing`): the test hears only the
-- tester's triggers and acts only on them; the live copy ignores the tester until the test ends. In
-- a test nothing of value stays: a card with a power runs its dryRun, which says what it would have
-- done (no money moves), and the items it hands out are stamped and taken back when it ends, F5
-- included (test_items.lua). Its variables start fresh and are never remembered.
--
-- It runs until stopped: the tester plays (the strip on their screen follows the card it is on), F9
-- brings the editor back with the test still going (its cards light as they run, each pin keeps its
-- last value, the log fills), and Stop or F5 (start again) end it. It also ends on a logout, a drop,
-- a new test, losing systems.build, whip_core stopping, or after TEST_MAX_MS.

--- How a value reads in the editor (hover a pin): short, and a player by name, never their session.
local function valueText(v)
    local t = type(v)
    if v == nil then return nil end
    if t == 'number' then
        if math.floor(v) == v and math.abs(v) < 1e15 then return ('%d'):format(v) end
        local s = ('%.3f'):format(v):gsub('0+$', '')
        return (s:gsub('%.$', ''))
    end
    if t == 'boolean' then return v and 'yes' or 'no' end
    if t == 'string' then
        if #v > 80 then v = C.cutText(v, 77) .. '...' end
        return '"' .. v .. '"'
    end
    if t == 'table' then
        if v.source ~= nil then
            local p = Players[v.source]
            return p and ('%s (#%s)'):format(p.fullName or '?', tostring(v.source)) or ('player #' .. tostring(v.source) .. ' (gone)')
        end
        if v.receipt ~= nil then return 'a receipt' end
        if type(v.x) == 'number' and type(v.y) == 'number' and type(v.z) == 'number' then
            return ('%.1f, %.1f, %.1f'):format(v.x, v.y, v.z)
        end
        local n = #v
        if n > 0 or next(v) == nil then return ('a list of %d'):format(n) end
        return 'a record'
    end
    return tostring(v)
end

local function report(t)
    local rep = R.report(t.inst)
    local values = {}
    for nodeId, pins in pairs(rep.values or {}) do
        local row = {}
        for k, v in pairs(pins) do row[k] = valueText(v) end
        values[nodeId] = row
    end
    local log = {}
    local now = GetGameTimer()
    for i, l in ipairs(rep.log) do
        log[i] = { ago = math.max(0, math.floor((now - (l.t or now)) / 1000)), level = l.level, node = l.node, msg = l.msg }
    end
    local trace = {}
    for i, e in ipairs(rep.trace) do
        trace[i] = { node = e.node, pin = e.pin, kind = e.kind, from = e.from, fromPin = e.fromPin, pulse = e.pulse }
    end
    return { key = t.key, name = t.name, status = t.inst.status == 'on' and 'running' or t.inst.status, reason = t.inst.reason,
             pulses = rep.pulses, steps = rep.steps, errors = rep.lastMinute.errors, ended = rep.lastMinute.ended,
             dropped = rep.dropped, values = values, log = log, trace = trace,
             seconds = math.floor((now - t.startedAt) / 1000) }
end

local function stepTitle(inst, e)
    local node = inst.graph.nodes[e.node]
    local def = node and node.def
    local pin = e.pin
    if def and def.labels and pin and def.labels[pin] then pin = def.labels[pin] end
    return { title = def and def.title or tostring(e.node), kind = e.kind, pin = pin }
end

endTest = function(src, why)
    local t = Systems.tests[src]
    if not t then return nil end
    t.ending = true
    local rep = report(t)
    R.stop(t.inst.id, why or 'the test was stopped')
    Systems.tests[src] = nil
    rep.status = 'stopped'
    rep.reason = why
    return rep
end

--- The walker stopped a Test by itself (it faulted): its tester is told, and it is gone.
function Systems.testStopped(inst, outcome, why)
    for src, t in pairs(Systems.tests) do
        if t.inst == inst then
            Systems.tests[src] = nil
            if not t.ending then
                TriggerClientEvent('whip_core:client:systemsTestEnded', src, { outcome = outcome, reason = why })
            end
        end
    end
end

--- `startedAt`: when the first of a run of tests of this system began (a restart or a new test of the
--- same one keeps it), so the 30-minute end cannot be put off by starting again.
local function startTest(src, key, name, row, graph, startedAt)
    local gen = Systems.nextGen()
    local t = { key = key, name = name, startedAt = startedAt or GetGameTimer(), steps = {}, flushing = false }
    -- Its own before it starts: a When Switched On card runs inside R.start, and what it does is the
    -- test's to show.
    Systems.tests[src] = t
    t.inst = R.start(graph, {
        key = key, gen = gen, tag = ('systest:%s:%d'):format(row.shortId, gen), test = true, only = src, watchValues = true,
        meta = { systemId = row.id, shortId = row.shortId, name = name, rev = 'test', owner = 'system:' .. row.shortId, test = true },
        -- What ran goes to the tester at most four times a second, the newest few: to the page when the
        -- editor is up (cards light), to the strip when they are playing.
        onTrace = function(e, inst)
            if Systems.tests[src] ~= t then return end
            local steps = t.steps
            steps[#steps + 1] = { node = e.node, pin = e.pin, kind = e.kind, from = e.from, fromPin = e.fromPin }
            if #steps > PULSE_MAX then table.remove(steps, 1) end
            t.latest = e
            if t.flushing then return end
            t.flushing = true
            SetTimeout(STEP_EVERY_MS, function()
                t.flushing = false
                if Systems.tests[src] ~= t then return end
                local list = t.steps
                t.steps = {}
                local latest = t.latest and stepTitle(inst, t.latest) or nil
                t.latest = nil
                -- With the system's key: the editor lights only that system's cards (another one's share ids).
                if #list > 0 then TriggerClientEvent('whip_core:client:systemsTestSteps', src, list, latest, key) end
            end)
        end,
    })
    -- Its points and the rest, for the tester alone (each card's standing() reads `test`).
    Systems.makeStanding(t.inst)
    return t
end

cb('test', { { 'key', 'key', 64 }, { 'token', 'id' } }, function(source, player, key, token)
    local why = off()
    if why then return false, why end
    local doc, uwhy = takeUpload(source, token)
    if not doc then return false, uwhy end
    local row = SystemStore.get(key)
    if not row then return false, 'No system called ' .. key end
    local graph, problems = SystemGraph.compile(doc, 'server')
    if not graph then return { ok = false, problems = problems } end
    -- AFTER THE WAIT, ASKED AGAIN (house rule): still here, still a builder.
    if not Players[source] then return false, 'You left' end
    if not Permissions.has(source, SB) then return false, 'You no longer build systems' end
    -- One editor's test at a time: a Director test owns the same strip and keys (F5, F9). Its test
    -- SESSION, not only its run: one whose run ended is still in Test mode on the player's game.
    if Director and Director.hasTest and Director.hasTest(source) then
        return false, 'A Director test is running: stop it first (F9 there)'
    end
    for _, run in ipairs(DirectorRuntime and DirectorRuntime.list() or {}) do
        if run.test and run.starter == source then return false, 'A Director test is running: stop it first (F9 there)' end
    end
    local prev = Systems.tests[source]
    local since = prev and prev.key == key and prev.startedAt or nil
    if prev then endTest(source, 'a new test started') end
    local name = type(doc.name) == 'string' and doc.name ~= '' and doc.name or row.name
    local t = startTest(source, key, name, row, graph, since)
    t.doc = doc
    -- The switched-on copy now leaves the tester be: said to the console and the admins online, so a
    -- test is never a quiet way out of what the live system does.
    if Systems.active[key] and not since then
        local text = ('%s is testing a draft of %s: the live one leaves them be until the test ends'):format(tostring(player.fullName), row.name)
        say('%s', text)
        for src in pairs(Players) do
            if src ~= source and Permissions.has(src, SA) then NotifyPlayer(src, text, 'info', 8000) end
        end
    end
    return { ok = true, name = name, live = Systems.active[key] ~= nil }
end, 1000)

cb('testReport', {}, function(source)
    local t = Systems.tests[source]
    if not t then return { status = 'none' } end
    return report(t)
end, 400)

cb('testStop', {}, function(source)
    local rep = endTest(source, 'the test was stopped')
    return rep or { status = 'none' }
end, 300, false)   -- their own test: ended even if they no longer build

-- F5 while playing: the same draft again, from fresh. No permission key: a builder who lost access
-- gets their test ENDED by it, only not started again.
SecureEvent('whip_core:server:systemsTestRestart', { whileDead = true, rateLimit = 1000, burst = 2 }, function(source)
    local t = Systems.tests[source]
    if not t then return end
    local doc, key = t.doc, t.key
    endTest(source, 'started again')
    local row = SystemStore.get(key)
    local graph = row and Permissions.has(source, SB) and doc and SystemGraph.compile(doc, 'server') or nil
    if not graph then
        TriggerClientEvent('whip_core:client:systemsTestEnded', source, { outcome = 'off', reason = 'it could not start again' })
        return
    end
    local nt = startTest(source, key, t.name, row, graph, t.startedAt)
    nt.doc = doc
    TriggerClientEvent('whip_core:client:systemsTestRestarted', source)
end)

-- Ended for good: tests that ran too long, and testers who are no longer builders.
Every('systems tests', 5000, function()
    if not next(Systems.tests) then return 5000 end
    local now = GetGameTimer()
    for src, t in pairs(Systems.tests) do
        local reason
        if not Players[src] then reason = 'the tester left'
        elseif not Permissions.has(src, SB) then reason = 'you no longer build systems'
        elseif now - t.startedAt > TEST_MAX_MS then reason = 'it ran for 30 minutes' end
        if reason then
            endTest(src, reason)
            if Players[src] then TriggerClientEvent('whip_core:client:systemsTestEnded', src, { outcome = 'off', reason = reason }) end
        end
    end
    return 5000
end)

-- ============================================
-- Live pulses: a switched-on system's cards light in the editor of whoever has it open
-- ============================================
--
-- Gathered per system and sent at most four times a second, the newest PULSE_MAX steps. Nothing is
-- gathered while nobody has it open. Card ids are the revision that is on: in a draft that moved on,
-- a card not there any more lights nothing.

local pulses = {}   -- [key] = { steps, flushing }

function Systems.livePulse(inst, e)
    if inst.test then return end
    local key = inst.key
    local watching = editing[key]
    if not watching or next(watching) == nil or type(e) ~= 'table' then return end
    local p = pulses[key]
    if not p then p = { steps = {} }; pulses[key] = p end
    local steps = p.steps
    steps[#steps + 1] = { node = e.node, pin = e.pin, kind = e.kind, from = e.from, fromPin = e.fromPin }
    if #steps > PULSE_MAX then table.remove(steps, 1) end
    if p.flushing then return end
    p.flushing = true
    SetTimeout(STEP_EVERY_MS, function()
        p.flushing = false
        local list = p.steps
        p.steps = {}
        if #list > 0 then
            for src in pairs(editing[key] or {}) do
                if Players[src] and Permissions.has(src, SB) then
                    TriggerClientEvent('whip_core:client:systemsPulse', src, key, list)
                end
            end
        end
        if not editing[key] then pulses[key] = nil end
    end)
end

-- ============================================
-- Who has what open
-- ============================================

--- The screen closed (or the editor went back to the hub): it is no longer editing anything. Its
--- uploads stay (Ctrl+S then Esc can close the screen between the upload landing and the save taking
--- it); they go when the player does (`gone`), or by age and count.
local function closed(src, gone)
    if gone then uploads[src] = nil end
    markEditing(src, nil)
end

-- No permission needed: it only forgets what the sender had open.
SecureEvent('whip_core:server:systemsClosed', { whileDead = true, rateLimit = 200, burst = 5 }, function(source)
    closed(source, false)
end)

AddEventHandler('playerDropped', function()
    local src = source
    closed(src, true)
    endTest(src, 'the tester left')
end)

Character.onLife('logout', function(e)
    if e and e.source then
        closed(e.source, true)
        endTest(e.source, 'the tester logged out')
    end
end)
